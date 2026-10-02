import XCTest
@testable import UnisonCore

/// A `sidx` box listing pieces of the given sizes, each [duration] long in [timescale] units.
func sidxBox(_ sizes: [UInt32], duration: UInt32 = 441_000, timescale: UInt32 = 44_100, version: UInt8 = 0,
             firstOffset: UInt64 = 0, referenceType: UInt32 = 0) -> Data {
    func be(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(value >> (8 * UInt64(count - 1 - $0)) & 0xFF) } }
    var body: [UInt8] = [version, 0, 0, 0] + be(1, 4) + be(UInt64(timescale), 4)
    body += version == 0 ? be(0, 4) + be(firstOffset, 4) : be(0, 8) + be(firstOffset, 8)
    body += be(0, 2) + be(UInt64(sizes.count), 2)
    for size in sizes {
        body += be(UInt64(referenceType << 31 | size), 4) + be(UInt64(duration), 4) + be(0x9000_0000, 4)
    }
    return Data(be(UInt64(body.count + 8), 4) + Array("sidx".utf8) + body)
}

final class HlsTests: XCTestCase {
    private func realIndex() throws -> Data {
        guard let url = Bundle.module.url(forResource: "sidx-140", withExtension: "bin", subdirectory: "Fixtures") else {
            throw XCTSkip("fixture missing")
        }
        return try Data(contentsOf: url)
    }

    func testTheIndexOfARealSongListsItsPiecesFromAfterTheIndexToTheEndOfTheFile() throws {
        // YouTube's AAC stream of a song of 4:24, whose index is at 723...1078 and which is 4261524 bytes long
        let segments = try DashIndex.segments(try realIndex(), at: 723)
        XCTAssertEqual(segments.count, 27)
        XCTAssertEqual(segments.first?.offset, 1079)
        XCTAssertEqual(segments.first?.size, 161_943)
        XCTAssertEqual(segments.first?.seconds ?? 0, 9.98458, accuracy: 0.0001)
        for (one, next) in zip(segments, segments.dropFirst()) { XCTAssertEqual(one.offset + one.size, next.offset, "no gaps") }
        XCTAssertEqual(segments.last.map { $0.offset + $0.size }, 4_261_524)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.seconds }, 264, accuracy: 1)
    }

    func testAnIndexOfTheSecondVersionWithAGapBeforeThePiecesIsRead() throws {
        let box = sidxBox([100, 200], duration: 22_050, version: 1, firstOffset: 5)
        let segments = try DashIndex.segments(box, at: 1000)
        XCTAssertEqual(segments, [
            DashSegment(offset: 1000 + Int64(box.count) + 5, size: 100, seconds: 0.5),
            DashSegment(offset: 1000 + Int64(box.count) + 105, size: 200, seconds: 0.5),
        ])
    }

    func testWhatIsNotAPlainIndexIsRefused() {
        XCTAssertThrowsError(try DashIndex.segments(sidxBox([100], referenceType: 1), at: 0), "an index of indexes")
        XCTAssertThrowsError(try DashIndex.segments(sidxBox([100]).prefix(30), at: 0), "cut short")
        XCTAssertThrowsError(try DashIndex.segments(sidxBox([]), at: 0), "lists nothing")
        XCTAssertThrowsError(try DashIndex.segments(sidxBox([0]), at: 0), "an empty piece")
        var other = sidxBox([100])
        other.replaceSubrange(4..<8, with: Array("moof".utf8))
        XCTAssertThrowsError(try DashIndex.segments(other, at: 0), "not an index")
        XCTAssertThrowsError(try DashIndex.segments(Data(), at: 0))
    }

    func testAPlaylistPlaysTheHeaderAndThenEachPieceAsARangeOfTheSameAddress() {
        let text = HlsPlaylist.media(url: "https://example.invalid/a?x=1&y=2", initEnd: 722, segments: [
            DashSegment(offset: 1079, size: 161_943, seconds: 9.98458),
            DashSegment(offset: 163_022, size: 5000, seconds: 0.3),
        ])
        XCTAssertEqual(text, """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="https://example.invalid/a?x=1&y=2",BYTERANGE="723@0"
        #EXTINF:9.984580,
        #EXT-X-BYTERANGE:161943@1079
        https://example.invalid/a?x=1&y=2
        #EXTINF:0.300000,
        #EXT-X-BYTERANGE:5000@163022
        https://example.invalid/a?x=1&y=2
        #EXT-X-ENDLIST

        """)
    }

    func testTheTargetLengthIsTheLongestPieceRoundedUp() {
        let text = HlsPlaylist.media(url: "u", initEnd: 1, segments: [DashSegment(offset: 2, size: 1, seconds: 5.0001)])
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:6\n"))
    }

    func testTheMasterPlaylistPlaysThePictureWithTheSound() {
        let video = URL(string: "unison-hls://playlist/2-v.m3u8")!
        let audio = URL(string: "unison-hls://playlist/1-a.m3u8")!
        XCTAssertEqual(HlsPlaylist.master(video: video, videoCodec: "avc1.4d401f", audio: audio, audioCodec: "mp4a.40.2", bandwidth: 830_000), """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="Sound",DEFAULT=YES,AUTOSELECT=YES,URI="unison-hls://playlist/1-a.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=830000,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="sound"
        unison-hls://playlist/2-v.m3u8

        """)
        let unknown = HlsPlaylist.master(video: video, videoCodec: "avc1.4d401f", audio: audio, audioCodec: nil, bandwidth: 0)
        XCTAssertTrue(unknown.contains("#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"sound\"\n"), "no codecs rather than half of them")
    }

    func testTheCodecIsReadFromTheType() {
        XCTAssertEqual(HlsPlaylist.codec(ofType: "audio/mp4; codecs=\"mp4a.40.2\""), "mp4a.40.2")
        XCTAssertNil(HlsPlaylist.codec(ofType: "audio/mp4"))
        XCTAssertNil(HlsPlaylist.codec(ofType: "audio/mp4; codecs=\"\""))
    }

    func testPlaylistsAreFoundByTheirAddressAndOnlyTheLastFewAreKept() {
        let playlists = HlsPlaylists()
        let first = playlists.add("one", name: "abc/../x-sound")
        XCTAssertEqual(first.scheme, HlsPlaylists.scheme)
        XCTAssertEqual(first.pathExtension, "m3u8")
        XCTAssertEqual(playlists.text(for: first), "one")
        let second = playlists.add("two", name: "abc-sound")
        XCTAssertNotEqual(first, second, "the same song twice gets two addresses")
        XCTAssertEqual(playlists.text(for: second), "two")
        XCTAssertNil(playlists.text(for: URL(string: "https://example.invalid/\(first.lastPathComponent)")!))
        for index in 0..<16 { _ = playlists.add("more \(index)", name: "n") }
        XCTAssertNil(playlists.text(for: first), "let go")
        XCTAssertNil(playlists.text(for: second), "let go")
    }

    func testTheRangesOfAStreamAreReadFromTheAnswer() throws {
        let format = try XCTUnwrap(JSON.parse(#"{"initRange":{"start":"0","end":"722"},"indexRange":{"start":"723","end":"8914"}}"#))
        XCTAssertEqual(DashRanges.of(format), DashRanges(initEnd: 722, indexStart: 723, indexEnd: 8914))
        XCTAssertNil(DashRanges.of(try XCTUnwrap(JSON.parse(#"{"initRange":{"start":"0","end":"722"}}"#))))
        XCTAssertNil(DashRanges.of(try XCTUnwrap(JSON.parse(#"{"initRange":{"start":"0","end":"800"},"indexRange":{"start":"723","end":"8914"}}"#))))
        XCTAssertNil(DashRanges.of(try XCTUnwrap(JSON.parse(#"{"initRange":{"start":"5","end":"722"},"indexRange":{"start":"723","end":"8914"}}"#))))
    }

    func testTheResolverKeepsTheRangesOfEachStream() throws {
        let answer = try XCTUnwrap(JSON.parse(#"""
        {"playabilityStatus":{"status":"OK"},"videoDetails":{"title":"T","author":"A","lengthSeconds":"264"},
         "streamingData":{"adaptiveFormats":[
          {"itag":140,"url":"https://a","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":130613,"contentLength":"4261524",
           "initRange":{"start":"0","end":"722"},"indexRange":{"start":"723","end":"1078"}},
          {"itag":136,"url":"https://v","mimeType":"video/mp4; codecs=\"avc1.4d401f\"","bitrate":1071542,"height":720,"contentLength":"23756332",
           "initRange":{"start":"0","end":"738"},"indexRange":{"start":"739","end":"1346"}}]}}
        """#))
        let resolved = try YouTubeResolver.resolved(answer, videoId: "JGwWNGJdvx8")
        XCTAssertEqual(resolved.best.index, DashRanges(initEnd: 722, indexStart: 723, indexEnd: 1078))
        XCTAssertEqual(resolved.videos.first?.index, DashRanges(initEnd: 738, indexStart: 739, indexEnd: 1346))
        XCTAssertEqual(resolved.videos.first?.contentLength, 23_756_332)
    }
}

/// Songs whose streams say where their pieces are: [audio] are (size, index box), the best first; [video] likewise.
final class IndexedResolver: StreamResolver, @unchecked Sendable {
    struct Stream {
        let size: Int64
        let index: Data?
    }

    var audio: [Stream]
    var video: Stream?
    private(set) var resolves = 0

    init(audio: [Stream], video: Stream? = nil) {
        self.audio = audio
        self.video = video
    }

    static let indexStart: Int64 = 723

    private static func ranges(_ stream: Stream) -> DashRanges? {
        stream.index.map { DashRanges(initEnd: indexStart - 1, indexStart: indexStart, indexEnd: indexStart + Int64($0.count) - 1) }
    }

    func search(_ query: String, limit: Int, songsOnly: Bool) async throws -> [TrackInfo] { [] }
    func resolve(_ videoId: String) async throws -> Resolved {
        resolves += 1
        let sources = audio.enumerated().map { number, stream in
            AudioSource(url: "https://example.invalid/a\(number)", mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", bitrateKbps: 128 - number,
                        contentLength: stream.size, itag: 140 - number, index: Self.ranges(stream))
        }
        let videos = video.map {
            [VideoSource(url: "https://example.invalid/v", height: 720, codec: "avc1.4d401f", bitrateKbps: 700, itag: 136,
                         contentLength: $0.size, index: Self.ranges($0))]
        } ?? []
        return Resolved(track: TrackInfo(videoId: videoId, title: "T", artist: "A", thumbUrl: nil, durationSec: 264),
                        best: sources[0], all: sources, videos: videos, userAgent: "test-agent")
    }
    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistRef] { [] }
    func playlist(_ playlistId: String, limit: Int) async throws -> Playlist { Playlist(title: "", tracks: []) }
    func related(_ videoId: String, limit: Int) async throws -> [TrackInfo] { [] }
    func suggest(_ query: String) async throws -> [String] { [] }
}

/// Serves the index boxes of [IndexedResolver]'s streams by range, and a whole file as long as its stream says; keeps
/// what it was asked for.
final class RangedFetcher: FileFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _whole: [String] = []
    private var _ranges: [String] = []
    let resolver: IndexedResolver

    init(_ resolver: IndexedResolver) { self.resolver = resolver }

    var whole: [String] { lock.withLock { _whole } }
    var ranges: [String] { lock.withLock { _ranges } }

    func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
        lock.withLock { _whole.append(url.lastPathComponent) }
        let size = stream(url)?.size ?? 0
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return size
    }

    func bytes(_ url: URL, range: ClosedRange<Int64>, headers: [String: String]) async throws -> Data {
        lock.withLock { _ranges.append("\(url.lastPathComponent) \(range.lowerBound)-\(range.upperBound) \(headers["User-Agent"] ?? "")") }
        guard let index = stream(url)?.index, range.lowerBound == IndexedResolver.indexStart else { throw URLError(.badServerResponse) }
        return index
    }

    private func stream(_ url: URL) -> IndexedResolver.Stream? {
        let name = url.lastPathComponent
        return name == "v" ? resolver.video : resolver.audio[Int(name.dropFirst()) ?? 0]
    }
}

final class PiecesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pieces-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A stream whose index lists [pieces] pieces of [size] bytes, so that the file is as long as it says.
    private func stream(pieces: Int, of size: UInt32) -> IndexedResolver.Stream {
        let box = sidxBox(Array(repeating: size, count: pieces))
        return IndexedResolver.Stream(size: IndexedResolver.indexStart + Int64(box.count) + Int64(pieces) * Int64(size), index: box)
    }

    private func library(_ resolver: IndexedResolver) -> (MediaLibrary, RangedFetcher, MediaFiles) {
        let files = MediaFiles(downloadsDir: dir.appendingPathComponent("d"), playDir: dir.appendingPathComponent("p"), playLimitBytes: 1 << 30)
        let fetcher = RangedFetcher(resolver)
        return (MediaLibrary(files: files, streams: StreamCache(resolver: resolver), fetcher: fetcher), fetcher, files)
    }

    func testASongThatIsNotOnTheDiskStartsFromItsPiecesWithoutBeingFetchedWhole() async throws {
        let (media, fetcher, _) = library(IndexedResolver(audio: [stream(pieces: 3, of: 1000)]))
        let playable = try await media.playableAtOnce("vid00000001")
        XCTAssertTrue(playable.isPlaylist)
        XCTAssertFalse(playable.isFile)
        XCTAssertEqual(playable.headers["User-Agent"], "test-agent")
        XCTAssertEqual(fetcher.whole, [])
        XCTAssertEqual(fetcher.ranges, ["a0 723-\(723 + 32 + 36 - 1) test-agent"])
        let text = try XCTUnwrap(media.playlists.text(for: playable.url))
        XCTAssertTrue(text.contains("#EXT-X-MAP:URI=\"https://example.invalid/a0\",BYTERANGE=\"723@0\"\n"))
        XCTAssertTrue(text.contains("#EXT-X-BYTERANGE:1000@\(723 + 68)\n"))
        XCTAssertEqual(text.components(separatedBy: "#EXTINF:10.000000,").count - 1, 3)
    }

    func testASongOnTheDiskIsPlayedFromItsFile() async throws {
        let (media, fetcher, files) = library(IndexedResolver(audio: [stream(pieces: 3, of: 1000)]))
        try Data(repeating: 1, count: 5).write(to: files.part("vid00000001", download: false))
        try files.finish("vid00000001", download: false)
        let playable = try await media.playableAtOnce("vid00000001")
        XCTAssertTrue(playable.isFile)
        XCTAssertEqual(fetcher.ranges, [])
    }

    func testAStreamWithoutAnIndexIsFetchedWholeAsBefore() async throws {
        let (media, fetcher, _) = library(IndexedResolver(audio: [IndexedResolver.Stream(size: 10, index: nil)]))
        let playable = try await media.playableAtOnce("vid00000001")
        XCTAssertTrue(playable.isFile)
        XCTAssertEqual(fetcher.whole, ["a0"])
        XCTAssertEqual(fetcher.ranges, [])
    }

    func testAnIndexThatDoesNotMatchTheFileIsTriedOnceMoreAndThenTheSongIsFetchedWhole() async throws {
        let wrong = IndexedResolver.Stream(size: 10, index: sidxBox([1000, 1000]))
        let (media, fetcher, _) = library(IndexedResolver(audio: [wrong]))
        let playable = try await media.playableAtOnce("vid00000001")
        XCTAssertTrue(playable.isFile)
        XCTAssertEqual(fetcher.ranges.count, 2)
        XCTAssertEqual(fetcher.whole, ["a0"])
    }

    func testTheNextSongIsFetchedWholeWhenItIsShortAndPlayedInPiecesWhenItIsLong() async throws {
        let short = IndexedResolver(audio: [stream(pieces: 3, of: 1000)])
        let (shortMedia, shortFetcher, _) = library(short)
        let kept = try await shortMedia.playable("vid00000001")
        XCTAssertTrue(kept.isFile)
        XCTAssertEqual(shortFetcher.whole, ["a0"])

        let long = IndexedResolver(audio: [stream(pieces: 3, of: 8 * 1024 * 1024)])
        let (longMedia, longFetcher, _) = library(long)
        let pieces = try await longMedia.playable("vid00000002")
        XCTAssertTrue(pieces.isPlaylist)
        XCTAssertEqual(longFetcher.whole, [])
    }

    func testWhenPiecesWillNotPlayALongSongIsFetchedWholeInASmallerQuality() async throws {
        let long = IndexedResolver(audio: [stream(pieces: 6, of: 8 * 1024 * 1024), IndexedResolver.Stream(size: 10, index: nil)])
        let (media, fetcher, _) = library(long)
        let playable = try await media.playable("vid00000001", piecesWhenLong: false)
        XCTAssertTrue(playable.isFile)
        XCTAssertEqual(fetcher.whole, ["a1"])
        XCTAssertEqual(fetcher.ranges, [])
    }

    func testAShortSongPlayedInPiecesIsKeptForNextTimeAndALongOneIsNot() async throws {
        let (media, fetcher, files) = library(IndexedResolver(audio: [stream(pieces: 3, of: 1000)]))
        await media.keep("vid00000001")
        XCTAssertEqual(fetcher.whole, ["a0"])
        XCTAssertNotNil(files.file("vid00000001"))
        await media.keep("vid00000001")
        XCTAssertEqual(fetcher.whole, ["a0"], "nothing more once it is there")

        let (longMedia, longFetcher, longFiles) = library(IndexedResolver(audio: [stream(pieces: 3, of: 8 * 1024 * 1024)]))
        await longMedia.keep("vid00000002")
        XCTAssertEqual(longFetcher.whole, [])
        XCTAssertNil(longFiles.file("vid00000002"))
    }

    func testThePictureAndTheSoundArePlayedTogetherFromTheirPieces() async throws {
        let resolver = IndexedResolver(audio: [stream(pieces: 3, of: 1000)], video: stream(pieces: 5, of: 3000))
        let (media, fetcher, _) = library(resolver)
        let both = try await XCTUnwrapAsync(await media.pictured("vid00000001", maxHeight: 720))
        XCTAssertTrue(both.isPlaylist)
        let master = try XCTUnwrap(media.playlists.text(for: both.url))
        XCTAssertTrue(master.contains("CODECS=\"avc1.4d401f,mp4a.40.2\""))
        XCTAssertTrue(master.contains("BANDWIDTH=828000"))
        let lines = master.split(separator: "\n")
        let pictureList = try XCTUnwrap(URL(string: String(lines.last!)))
        let soundURI = try XCTUnwrap(master.components(separatedBy: "URI=\"").last?.components(separatedBy: "\"").first)
        let soundList = try XCTUnwrap(URL(string: soundURI))
        XCTAssertTrue(try XCTUnwrap(media.playlists.text(for: pictureList)).contains("https://example.invalid/v"))
        XCTAssertTrue(try XCTUnwrap(media.playlists.text(for: soundList)).contains("https://example.invalid/a0"))
        XCTAssertEqual(fetcher.whole, [])
    }

    func testAStreamThatBrokeIsResolvedAgainWhenItIsLoadedNext() async throws {
        let resolver = IndexedResolver(audio: [stream(pieces: 3, of: 1000)])
        let (media, _, _) = library(resolver)
        _ = try await media.playableAtOnce("vid00000001")
        _ = try await media.playableAtOnce("vid00000001")
        XCTAssertEqual(resolver.resolves, 1, "an address is kept while it works")
        await media.refresh("vid00000001")
        _ = try await media.playableAtOnce("vid00000001")
        XCTAssertEqual(resolver.resolves, 2)
    }

    func testWithoutAnIndexForThePictureThereIsNoPlaylistOfBoth() async throws {
        let resolver = IndexedResolver(audio: [stream(pieces: 3, of: 1000)], video: IndexedResolver.Stream(size: 10, index: nil))
        let (media, _, _) = library(resolver)
        let both = try await media.pictured("vid00000001", maxHeight: 720)
        XCTAssertNil(both)
    }
}

/// XCTUnwrap for a value that took an await to get.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let got = try await value()
    return try XCTUnwrap(got, file: file, line: line)
}
