import XCTest
@testable import SapocheCore

/// Songs come from YouTube as MP4 in fragments; the player is given an ordinary MP4 instead. The two fixtures are a
/// second and a half of a tone in 4 fragments: one whose fragments address their samples from the start of the
/// fragment, one that gives a data offset. Both hold 66 AAC frames, in 6172 and 6140 bytes.
final class Mp4Tests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "m4a", subdirectory: "Fixtures") else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no fixture \(name)"])
        }
        return try Data(contentsOf: url)
    }

    private func topLevel(_ data: Data) -> [(type: String, start: Int, size: Int)] {
        var found: [(String, Int, Int)] = []
        var at = 0
        while at + 8 <= data.count {
            let size = data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
            found.append((String(decoding: data[at + 4..<at + 8], as: UTF8.self), at, size))
            at += size
        }
        return found
    }

    private func children(_ data: Data, of box: (type: String, start: Int, size: Int)) -> [(type: String, start: Int, size: Int)] {
        topLevel(Data(data[box.start + 8..<box.start + box.size])).map { ($0.type, $0.start + box.start + 8, $0.size) }
    }

    private func check(_ name: String, mdatBytes: Int) throws {
        let source = try fixtureData(name)
        let out = try Mp4Remux.progressive(source)
        let boxes = topLevel(out)
        XCTAssertEqual(boxes.map(\.type), ["ftyp", "moov", "mdat"])
        XCTAssertEqual(boxes.last?.size, mdatBytes + 8)
        XCTAssertEqual(out.count, boxes.reduce(0) { $0 + $1.size }, "no byte is left over")

        // The tables say what is in the mdat
        let moov = boxes[1]
        let track = try XCTUnwrap(children(out, of: moov).first { $0.type == "trak" })
        let media = try XCTUnwrap(children(out, of: track).first { $0.type == "mdia" })
        let info = try XCTUnwrap(children(out, of: media).first { $0.type == "minf" })
        let table = try XCTUnwrap(children(out, of: info).first { $0.type == "stbl" })
        let tables = Dictionary(uniqueKeysWithValues: children(out, of: table).map { ($0.type, $0) })
        func number(_ box: (type: String, start: Int, size: Int)?, _ index: Int) -> Int {
            guard let box else { return -1 }
            let at = box.start + 8 + index * 4
            return out[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        XCTAssertEqual(number(tables["stsz"], 2), 66, "66 samples")
        let sizes = (0..<66).map { number(tables["stsz"], 3 + $0) }
        XCTAssertEqual(sizes.reduce(0, +), mdatBytes)
        XCTAssertEqual(number(tables["stco"], 1), 4, "one chunk for each fragment")
        let firstChunk = number(tables["stco"], 2)
        XCTAssertEqual(firstChunk, boxes[2].start + 8, "the first chunk is where the data starts")
        XCTAssertEqual(number(tables["stsd"], 1), 1)
        XCTAssertFalse(out.range(of: Data("moof".utf8)) != nil, "no fragment is left")
    }

    func testFragmentsThatCountFromTheirOwnStartBecomeOneFile() throws {
        try check("frag_moof_base", mdatBytes: 6172)
    }

    func testFragmentsThatGiveADataOffsetBecomeOneFile() throws {
        try check("frag_data_offset", mdatBytes: 6140)
    }

    func testTheSamplesKeepTheirBytesAndOrder() throws {
        let source = try fixtureData("frag_moof_base")
        let out = try Mp4Remux.progressive(source)
        var original = Data()
        for box in topLevel(source) where box.type == "mdat" { original.append(source[box.start + 8..<box.start + box.size]) }
        let mdat = try XCTUnwrap(topLevel(out).last)
        XCTAssertEqual(Data(out[mdat.start + 8..<mdat.start + mdat.size]), original)
    }

    func testAFileIsConvertedInPlaceAndOnlyOnce() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("remux-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try fixtureData("frag_moof_base").write(to: file)
        XCTAssertTrue(Mp4Remux.isFragmented(file))
        XCTAssertTrue(try Mp4Remux.makeProgressive(file))
        XCTAssertFalse(Mp4Remux.isFragmented(file))
        XCTAssertFalse(try Mp4Remux.makeProgressive(file), "an ordinary file is left as it is")
        XCTAssertEqual(try Data(contentsOf: file).prefix(4), try Mp4Remux.progressive(fixtureData("frag_moof_base")).prefix(4))
    }

    func testAFileThatIsNotAnMp4IsLeftAlone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not an mp4 at all, just some text".utf8).write(to: file)
        XCTAssertFalse(Mp4Remux.isFragmented(file))
        XCTAssertFalse(try Mp4Remux.makeProgressive(file))
        XCTAssertThrowsError(try Mp4Remux.progressive(Data("not an mp4 at all, just some text".utf8)))
    }

    func testAFileCutShortIsRefusedAndKept() throws {
        let source = try fixtureData("frag_moof_base")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cut-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        let cut = source.prefix(source.count - 1000)
        try cut.write(to: file)
        XCTAssertThrowsError(try Mp4Remux.makeProgressive(file))
        XCTAssertEqual(try Data(contentsOf: file), Data(cut), "the file is as it was")
    }

    // ------------------------------------------------------------------ in the library

    private final class Source: StreamResolver, @unchecked Sendable {
        let length: Int64
        init(length: Int64) { self.length = length }
        func search(_ query: String, limit: Int, songsOnly: Bool) async throws -> [TrackInfo] { [] }
        func resolve(_ videoId: String) async throws -> Resolved {
            let source = AudioSource(url: "https://example.invalid/\(videoId)", mimeType: "audio/mp4", bitrateKbps: 128, contentLength: length, itag: 140)
            return Resolved(track: TrackInfo(videoId: videoId, title: "T", artist: "A", thumbUrl: nil, durationSec: 2), best: source, all: [source], userAgent: "ua")
        }
        func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistRef] { [] }
        func playlist(_ playlistId: String, limit: Int) async throws -> Playlist { Playlist(title: "", tracks: []) }
        func related(_ videoId: String, limit: Int) async throws -> [TrackInfo] { [] }
        func suggest(_ query: String) async throws -> [String] { [] }
    }

    private struct Delivers: FileFetcher {
        let data: Data
        func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
            try data.write(to: file)
            return Int64(data.count)
        }
    }

    private func library(_ data: Data) -> (MediaLibrary, MediaFiles) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp4-\(UUID().uuidString)")
        let files = MediaFiles(downloadsDir: dir.appendingPathComponent("d"), playDir: dir.appendingPathComponent("p"), playLimitBytes: 1 << 20)
        let media = MediaLibrary(files: files, streams: StreamCache(resolver: Source(length: Int64(data.count))), fetcher: Delivers(data: data))
        return (media, files)
    }

    func testASongFromYouTubeIsKeptAsAnOrdinaryFile() async throws {
        let (media, files) = library(try fixtureData("frag_moof_base"))
        let playable = try await media.playable("vid00000001")
        XCTAssertTrue(playable.isFile)
        XCTAssertFalse(Mp4Remux.isFragmented(playable.url))
        XCTAssertEqual(playable.url, files.played("vid00000001"))
        XCTAssertGreaterThan(try Data(contentsOf: playable.url).count, 6172)
    }

    func testASongKeptByAnEarlierVersionIsRewrittenWhenPlayed() async throws {
        let (media, files) = library(Data())
        try fixtureData("frag_data_offset").write(to: files.played("vid00000002"))
        XCTAssertTrue(Mp4Remux.isFragmented(files.played("vid00000002")))
        let playable = try await media.playable("vid00000002")
        XCTAssertFalse(Mp4Remux.isFragmented(playable.url))
    }

    func testAFileThePlayerRefusedIsForgottenAndTheStreamIsOffered() async throws {
        let (media, files) = library(try fixtureData("frag_moof_base"))
        _ = try await media.playable("vid00000003")
        XCTAssertNotNil(files.file("vid00000003"))
        await media.forget("vid00000003")
        XCTAssertNil(files.file("vid00000003"))
        let stream = try await media.streamed("vid00000003")
        XCTAssertFalse(stream.isFile)
        XCTAssertEqual(stream.url.absoluteString, "https://example.invalid/vid00000003")
        XCTAssertEqual(stream.headers["User-Agent"], "ua")
    }
}
