import XCTest
@testable import UnisonCore

/// The readers against answers YouTube Music really gave (cut short), so a change of shape shows up here.
final class MusicParserTests: XCTestCase {
    private func client(_ answers: [String: String]) -> MusicClient {
        MusicClient { endpoint, _ in
            guard let name = answers[endpoint], let json = JSON.parse(data: try fixture(name)) else { throw URLError(.fileDoesNotExist) }
            return json
        }
    }

    func testTheRadioOfASongStartsWithItAndKnowsItIsASong() async throws {
        let next = try await client(["next": "next_song"]).watchNext("lYBUbBu4W08")
        let first = try XCTUnwrap(next.tracks.first)
        XCTAssertEqual(first.videoId, "lYBUbBu4W08")
        XCTAssertEqual(first.title, "Never Gonna Give You Up")
        XCTAssertEqual(first.artist, "Rick Astley")
        XCTAssertEqual(first.artistId, "UCwZEU0wAwIyZb4x5G_KJp2w")
        XCTAssertEqual(first.album, "Whenever You Need Somebody")
        XCTAssertEqual(first.year, "1987")
        XCTAssertEqual(first.durationSec, 214)
        XCTAssertNil(first.stats)
        XCTAssertTrue(first.isSong)
        XCTAssertTrue(next.tracks.dropFirst().allSatisfy(\.isSong), "the radio of a song is made of songs")
        XCTAssertNotNil(next.lyricsId)
        XCTAssertNotNil(next.relatedId)
    }

    func testTheRadioOfAVideoIsMadeOfVideos() async throws {
        let next = try await client(["next": "next_video"]).watchNext("dQw4w9WgXcQ")
        let first = try XCTUnwrap(next.tracks.first)
        XCTAssertEqual(first.videoId, "dQw4w9WgXcQ")
        XCTAssertFalse(first.isSong)
        XCTAssertEqual(first.artist, "Rick Astley", "the views and likes that follow are not part of the artist")
        XCTAssertNil(first.album)
        XCTAssertNil(first.year)
        XCTAssertEqual(first.stats, "1.8B views · 19M likes")
    }

    func testACoverIsAskedForAtASizeFitForThePlayer() async throws {
        let first = try await client(["next": "next_song"]).watchNext("lYBUbBu4W08").tracks[0]
        XCTAssertTrue(try XCTUnwrap(first.thumbUrl).contains("=w544-h544"), first.thumbUrl ?? "")
    }

    func testTheRelatedPageHasSongsOtherPerformancesArtistsAndPlaylists() async throws {
        let related = try await client(["browse": "related"]).related("MPTRt_x")
        XCTAssertFalse(related.more.isEmpty)
        XCTAssertEqual(related.more[0].videoId, "QAo_Ycocl1E")
        XCTAssertFalse(related.artists.isEmpty)
        XCTAssertTrue(related.artists[0].id.hasPrefix("UC"))
        XCTAssertFalse(related.playlists.isEmpty)
        XCTAssertFalse(related.otherPerformances.isEmpty)
        XCTAssertTrue(try XCTUnwrap(related.about).hasPrefix("Richard Paul Astley"))
    }

    func testLyricsComeAsPlainText() async throws {
        let words = try await client(["browse": "lyrics"]).lyrics("MPLYt_x")
        XCTAssertTrue(try XCTUnwrap(words).hasPrefix("We're no strangers to love"))
    }

    func testAnArtistHasAPictureABioTopSongsAndReleases() async throws {
        let artist = try await client(["browse": "artist"]).artist("UCwZEU0wAwIyZb4x5G_KJp2w")
        XCTAssertEqual(artist.name, "Rick Astley")
        XCTAssertTrue(try XCTUnwrap(artist.description).hasPrefix("Richard Paul Astley"))
        XCTAssertEqual(artist.subscribers?.split(separator: " ").first.map(String.init), "4.55M")
        XCTAssertNotNil(artist.thumbUrl)
        XCTAssertFalse(artist.topSongs.isEmpty)
        XCTAssertFalse(artist.albums.isEmpty)
        XCTAssertTrue(artist.albums.allSatisfy { $0.id.hasPrefix("MPRE") })
        XCTAssertFalse(artist.singles.isEmpty)
        XCTAssertFalse(artist.similar.isEmpty)
    }

    func testASearchForSongsGivesSongsAndOneForVideosGivesVideos() async throws {
        let songs = try await client(["search": "search_songs"]).searchSongs("chung ta cua hien tai")
        XCTAssertEqual(songs[0].title, "Chúng Ta Của Hiện Tại")
        XCTAssertEqual(songs[0].artist, "Sơn Tùng M-TP")
        XCTAssertEqual(songs[0].durationSec, 302)
        XCTAssertTrue(songs.allSatisfy(\.isSong))

        let videos = try await client(["search": "search_videos"]).searchVideos("chung ta cua hien tai")
        XCTAssertFalse(videos.isEmpty)
        XCTAssertTrue(videos.allSatisfy { !$0.isSong })
        XCTAssertTrue(videos.allSatisfy { $0.durationSec > 0 })
    }

    func testTheHomePageHasShelvesOfSongsOrPlaylists() async throws {
        let shelves = try await client(["browse": "home"]).trending(language: "en")
        XCTAssertFalse(shelves.isEmpty)
        XCTAssertTrue(shelves.allSatisfy { !$0.title.isEmpty && (!$0.tracks.isEmpty || !$0.playlists.isEmpty) })
        XCTAssertTrue(shelves.flatMap(\.playlists).allSatisfy { !$0.id.isEmpty })
    }

    func testAPlaylistPageGivesItsSongsAndName() async throws {
        let found = try await client(["browse": "music_playlist"]).playlist("PLx")
        XCTAssertEqual(found.title, "Popular Music Videos")
        XCTAssertEqual(found.tracks.count, 6)
        XCTAssertTrue(found.tracks.allSatisfy { $0.durationSec > 0 && !$0.videoId.isEmpty })
    }

    func testAnAnswerOfAShapeThatIsNotKnownGivesNothingInsteadOfFailing() async throws {
        let client = MusicClient { _, _ in JSON.parse(#"{"unexpected":[1,2,{"a":null}]}"#)! }
        let next = try await client.watchNext("x")
        XCTAssertTrue(next.tracks.isEmpty)
        let lyrics = try await client.lyrics("x")
        XCTAssertNil(lyrics)
        let songs = try await client.searchSongs("x")
        XCTAssertTrue(songs.isEmpty)
        let artist = try await client.artist("UC")
        XCTAssertEqual(artist.name, "")
        let shelves = try await client.trending(language: "en")
        XCTAssertTrue(shelves.isEmpty)
    }

    func testTheOtherReleaseIsReadWhenYouTubeNamesIt() async throws {
        func row(_ id: String, _ title: String, _ length: String, _ type: String) -> String {
            """
            {"videoId":"\(id)","title":{"runs":[{"text":"\(title)"}]},"longBylineText":{"runs":[{"text":"A"}]},
             "lengthText":{"runs":[{"text":"\(length)"}]},
             "navigationEndpoint":{"watchEndpoint":{"watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"\(type)"}}}}}
            """
        }
        let answer = """
        {"contents":{"singleColumnMusicWatchNextResultsRenderer":{"tabbedRenderer":{"watchNextTabbedResultsRenderer":{"tabs":[
          {"tabRenderer":{"content":{"musicQueueRenderer":{"content":{"playlistPanelRenderer":{"contents":[
            {"playlistPanelVideoWrapperRenderer":{
              "primaryRenderer":{"playlistPanelVideoRenderer":\(row("song1", "T", "3:00", "MUSIC_VIDEO_TYPE_ATV"))},
              "counterpart":[{"counterpartRenderer":{"playlistPanelVideoRenderer":\(row("clip1", "T (Official Video)", "3:20", "MUSIC_VIDEO_TYPE_OMV"))}}]}}
          ]}}}}}}
        ]}}}}}
        """
        let tracks = try await MusicClient { _, _ in JSON.parse(answer)! }.watchNext("song1").tracks
        XCTAssertEqual(tracks.count, 1)
        let track = tracks[0]
        XCTAssertTrue(track.isSong)
        XCTAssertEqual(track.counterpart?.videoId, "clip1")
        XCTAssertEqual(track.counterpart?.isSong, false)
        XCTAssertEqual(track.counterpart?.durationSec, 200)
    }

    func testLengthsAreReadInMinutesAndHours() {
        XCTAssertEqual(MusicParser.seconds("3:34"), 214)
        XCTAssertEqual(MusicParser.seconds("1:02:03"), 3723)
        XCTAssertEqual(MusicParser.seconds("710K views"), 0)
        XCTAssertEqual(MusicParser.seconds(nil), 0)
    }

    func testOnlyTheHomePageIsAskedForInTheLanguageOfThePersonEverythingElseInEnglish() async throws {
        let bodies = Collected()
        let client = MusicClient(region: { "VN" }) { _, body in
            await bodies.add(body)
            return JSON.parse("{}")!
        }
        _ = try await client.watchNext("x")
        _ = try await client.lyrics("x")
        _ = try await client.searchSongs("x")
        _ = try await client.trending(language: "vi")
        let sent = await bodies.items
        func field(_ body: [String: Any], _ name: String) -> String? {
            ((body["context"] as? [String: Any])?["client"] as? [String: Any])?[name] as? String
        }
        // The readers find lyrics and related songs by the English names of their tabs, so these must not change
        XCTAssertTrue(sent.dropLast().allSatisfy { field($0, "hl") == "en" })
        XCTAssertEqual(field(sent.last!, "hl"), "vi")
        // The country only decides what is shown first, never the words
        XCTAssertTrue(sent.allSatisfy { field($0, "gl") == "VN" })
    }

    func testAMissingCountryFallsBackToTheUnitedStates() async throws {
        let bodies = Collected()
        _ = try await MusicClient(region: { "" }) { _, body in
            await bodies.add(body)
            return JSON.parse("{}")!
        }.searchVideos("x")
        let sent = await bodies.items
        let body = try XCTUnwrap(sent.first)
        XCTAssertEqual(((body["context"] as? [String: Any])?["client"] as? [String: Any])?["gl"] as? String, "US")
    }
}

actor Collected {
    private(set) var items: [[String: Any]] = []

    func add(_ item: [String: Any]) { items.append(item) }
}

final class LyricsTests: XCTestCase {
    func testLinesAreReadWithTheirTimesInOrder() {
        let lines = Lrc.parse("[ar:Someone]\n[00:12.50] Second\n[00:01.00]First\n[01:02.05]Third")
        XCTAssertEqual(lines, [LyricLine(ms: 1000, text: "First"), LyricLine(ms: 12_500, text: "Second"), LyricLine(ms: 62_050, text: "Third")])
    }

    func testALineWithSeveralTimesIsSungEachTime() {
        XCTAssertEqual(Lrc.parse("[00:10.00][00:30.00]Chorus"), [LyricLine(ms: 10_000, text: "Chorus"), LyricLine(ms: 30_000, text: "Chorus")])
    }

    func testAnEmptyLineIsKeptAsAPauseAndFractionsAreReadAsTheyAre() {
        XCTAssertEqual(Lrc.parse("[00:05.5]\n[00:06.01]x"), [LyricLine(ms: 5500, text: ""), LyricLine(ms: 6010, text: "x")])
    }

    func testTextThatIsNotLyricsWithTimesGivesNoLines() {
        XCTAssertEqual(Lrc.parse("Just words\nmore words"), [])
    }

    private actor FakeLrclib {
        let answers: [String: String]
        private(set) var asked: [String] = []

        init(_ answers: [String: String]) { self.answers = answers }

        func get(_ url: String) -> String? {
            asked.append(url)
            return answers.first { url.contains($0.key) }?.value
        }
    }

    private func client(_ fake: FakeLrclib) -> LyricsClient {
        LyricsClient { await fake.get($0) }
    }

    private let synced = #"{"duration":213.0,"instrumental":false,"plainLyrics":"One\nTwo","syncedLyrics":"[00:01.00] One\n[00:02.00] Two"}"#

    func testAnExactMatchGivesTheLyricsWithTimes() async throws {
        let lyrics = try await client(FakeLrclib(["api/get": synced])).find(title: "Song", artist: "Artist", durationSec: 214)
        let found = try XCTUnwrap(lyrics)
        XCTAssertTrue(found.synced)
        XCTAssertEqual(found.lines.map(\.text), ["One", "Two"])
        XCTAssertEqual(found.plain, "One\nTwo")
    }

    func testTheServiceIsToldTheNameAndTheLengthAndNothingElse() async throws {
        let fake = FakeLrclib(["api/get": synced])
        _ = try await client(fake).find(title: "Song", artist: "Artist", durationSec: 214)
        let asked = await fake.asked
        XCTAssertEqual(asked, ["https://lrclib.net/api/get?track_name=Song&artist_name=Artist&duration=214"])
    }

    func testWhenTheNameWithTagsIsNotKnownTheNameWithoutThemIsTried() async throws {
        let fake = FakeLrclib(["track_name=Song&artist_name=Artist&": synced])
        let lyrics = try await client(fake).find(title: "Song (Official Video)", artist: "Artist - Topic", durationSec: 214)
        XCTAssertTrue(try XCTUnwrap(lyrics).synced)
        let asked = await fake.asked
        XCTAssertEqual(asked.count, 2)
    }

    func testWithoutAnExactMatchTheNearestLengthWithLinesWins() async throws {
        let search = """
        [{"duration":300.0,"plainLyrics":"far","syncedLyrics":"[00:01.00] far"},
         {"duration":212.0,"plainLyrics":"plain only","syncedLyrics":null},
         {"duration":215.0,"plainLyrics":"near","syncedLyrics":"[00:01.00] near"}]
        """
        let lyrics = try await client(FakeLrclib(["api/search": search])).find(title: "Song", artist: "Artist", durationSec: 214)
        XCTAssertEqual(try XCTUnwrap(lyrics).lines.map(\.text), ["near"])
    }

    func testLyricsOfAMuchLongerRecordingAreNotUsed() async throws {
        let search = #"[{"duration":400.0,"plainLyrics":"other","syncedLyrics":"[00:01.00] other"}]"#
        let lyrics = try await client(FakeLrclib(["api/search": search])).find(title: "Song", artist: "Artist", durationSec: 214)
        XCTAssertNil(lyrics)
    }

    func testAnInstrumentalAndASongNobodyWroteDownGiveNothing() async throws {
        let instrumental = #"{"duration":214.0,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#
        let first = try await client(FakeLrclib(["api/get": instrumental])).find(title: "Song", artist: "Artist", durationSec: 214)
        XCTAssertNil(first)
        let second = try await client(FakeLrclib([:])).find(title: "Song", artist: "Artist", durationSec: 214)
        XCTAssertNil(second)
    }

    func testPlainWordsAreKeptWhenThereAreNoTimes() async throws {
        let plain = #"{"duration":214.0,"plainLyrics":"Only words","syncedLyrics":null}"#
        let lyrics = try await client(FakeLrclib(["api/get": plain])).find(title: "Song", artist: "Artist", durationSec: 214)
        let found = try XCTUnwrap(lyrics)
        XCTAssertFalse(found.synced)
        XCTAssertEqual(found.plain, "Only words")
    }

    func testTagsThatOnlyDescribeTheRecordingAreTakenOffTheTitle() {
        XCTAssertEqual(SongNames.title("Never Gonna Give You Up (Official Video)"), "Never Gonna Give You Up")
        XCTAssertEqual(SongNames.title("Take On Me [Official Music Video] [HD]"), "Take On Me")
        XCTAssertEqual(SongNames.title("Song (feat. Someone)"), "Song")
        XCTAssertEqual(SongNames.title("Song (2009 Remaster)"), "Song")
        XCTAssertEqual(SongNames.title("Song (Remix)"), "Song (Remix)", "a remix is another recording")
        XCTAssertEqual(SongNames.title("Song (Live)"), "Song (Live)")
        XCTAssertEqual(SongNames.title("(Official)"), "(Official)", "never leaves nothing")
    }

    func testALeadingArtistNameIsDroppedFromTheTitle() {
        XCTAssertEqual(SongNames.title("Adele - Hello", artist: "Adele"), "Hello")
        XCTAssertEqual(SongNames.title("A - B", artist: "Someone else"), "A - B")
    }

    func testTheFirstArtistIsTheMainOne() {
        XCTAssertEqual(SongNames.artist("Sơn Tùng M-TP"), "Sơn Tùng M-TP")
        XCTAssertEqual(SongNames.artist("Rick Astley - Topic"), "Rick Astley")
        XCTAssertEqual(SongNames.artist("Adele VEVO"), "Adele")
        XCTAssertEqual(SongNames.artist("A, B & C"), "A")
        XCTAssertEqual(SongNames.artist("A feat. B"), "A")
        XCTAssertEqual(SongNames.artist("Wham!"), "Wham!")
    }
}

final class MusicFeedTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private final class FakeMusic: MusicSource, @unchecked Sendable {
        var nextCalls = 0
        var lyricsCalls = 0
        var trendingCalls: [String] = []
        var plain: String? = "plain from youtube"
        var lyricsId: String? = "MPLY"
        var shelf: String?

        func watchNext(_ videoId: String, radio: Bool) async throws -> WatchNext {
            nextCalls += 1
            return WatchNext(tracks: [MusicTrack(videoId: videoId, title: "T", artist: "A")], lyricsId: lyricsId, relatedId: "MPTR")
        }

        func related(_ relatedId: String) async throws -> Related {
            Related(more: [], otherPerformances: [], artists: [], playlists: [], about: nil)
        }

        func lyrics(_ lyricsId: String) async throws -> String? {
            lyricsCalls += 1
            return plain
        }

        func artist(_ artistId: String) async throws -> ArtistPage {
            ArtistPage(id: artistId, name: "N", description: nil, subscribers: nil, thumbUrl: nil, topSongs: [], albums: [], singles: [], similar: [])
        }

        func searchSongs(_ query: String) async throws -> [MusicTrack] { [MusicTrack(videoId: "song", title: "T", artist: "A", isSong: true)] }
        func searchVideos(_ query: String) async throws -> [MusicTrack] { [MusicTrack(videoId: "clip", title: "T", artist: "A")] }
        func playlist(_ playlistId: String) async throws -> (title: String?, tracks: [MusicTrack]) { (nil, []) }

        func trending(language: String) async throws -> [MusicShelf] {
            trendingCalls.append(language)
            return [MusicShelf(title: "Hits in \(language)", tracks: [MusicTrack(videoId: "a", title: "T", artist: "A")])]
        }
    }

    private final class FakeLrclib: @unchecked Sendable {
        var body: String?
        var asked = 0

        init(_ body: String?) { self.body = body }

        func get(_ url: String) -> String? {
            asked += 1
            return body
        }
    }

    private final class Clock: @unchecked Sendable {
        var time: Int64 = 0
    }

    private let synced = #"{"duration":214.0,"plainLyrics":"One","syncedLyrics":"[00:01.00] One"}"#

    private func feed(_ music: FakeMusic, _ lrclib: FakeLrclib, _ clock: Clock = Clock()) -> MusicFeed {
        MusicFeed(music: music, lyricsClient: LyricsClient { lrclib.get($0) }, lyricsStore: LyricsStore(dir: dir), now: { clock.time })
    }

    func testLyricsWithTimesFromLRCLIBWinOverThePlainWordsOfYouTube() async throws {
        let music = FakeMusic()
        let lyrics = try await feed(music, FakeLrclib(synced)).lyrics(videoId: "id1", title: "T", artist: "A", durationSec: 214)
        XCTAssertTrue(try XCTUnwrap(lyrics).synced)
        XCTAssertEqual(music.lyricsCalls, 0)
    }

    func testWhenLRCLIBHasNothingThePlainWordsOfYouTubeAreUsed() async throws {
        let lyrics = try await feed(FakeMusic(), FakeLrclib(nil)).lyrics(videoId: "id1", title: "T", artist: "A", durationSec: 214)
        let found = try XCTUnwrap(lyrics)
        XCTAssertFalse(found.synced)
        XCTAssertEqual(found.plain, "plain from youtube")
    }

    func testPlainWordsFromLRCLIBAreTheLastResort() async throws {
        let music = FakeMusic()
        music.plain = nil
        let lyrics = try await feed(music, FakeLrclib(#"{"duration":214.0,"plainLyrics":"Words","syncedLyrics":null}"#))
            .lyrics(videoId: "id1", title: "T", artist: "A", durationSec: 214)
        XCTAssertEqual(try XCTUnwrap(lyrics).plain, "Words")
    }

    func testASongLookedUpOnceIsNotAskedForAgain() async throws {
        let music = FakeMusic()
        let lrclib = FakeLrclib(synced)
        let first = feed(music, lrclib)
        _ = try await first.lyrics(videoId: "id1", title: "T", artist: "A", durationSec: 214)
        let asked = lrclib.asked
        let again = try await first.lyrics(videoId: "id1", title: "T", artist: "A", durationSec: 214)
        XCTAssertEqual(try XCTUnwrap(again).lines.first?.text, "One")
        XCTAssertEqual(lrclib.asked, asked)
        // Nor after a restart: a new feed on the same files
        _ = try await feed(music, lrclib).lyrics(videoId: "id1", title: "T", artist: "A", durationSec: 214)
        XCTAssertEqual(lrclib.asked, asked)
    }

    func testASongWithoutLyricsIsAskedAboutAgainOnlyAfterAWeek() async throws {
        let clock = Clock()
        clock.time = 1_000
        let music = FakeMusic()
        music.lyricsId = nil
        let lrclib = FakeLrclib(nil)
        let feed = feed(music, lrclib, clock)
        let first = try await feed.lyrics(videoId: "id1", title: "T", artist: "A", durationSec: 214)
        XCTAssertNil(first)
        let asked = lrclib.asked
        clock.time += 60_000
        let second = try await feed.lyrics(videoId: "id1", title: "T", artist: "A", durationSec: 214)
        XCTAssertNil(second)
        XCTAssertEqual(lrclib.asked, asked, "a minute later nothing is asked")

        clock.time += MusicFeed.missingMs
        lrclib.body = synced
        let later = try await feed.lyrics(videoId: "id1", title: "T", artist: "A", durationSec: 214)
        XCTAssertTrue(try XCTUnwrap(later).synced)
    }

    func testTheRadioOfASongIsAskedForOnceWhileItIsFresh() async throws {
        let music = FakeMusic()
        let feed = feed(music, FakeLrclib(nil))
        _ = try await feed.watchNext("id1")
        _ = try await feed.watchNext("id1")
        _ = try await feed.related("id1")
        XCTAssertEqual(music.nextCalls, 1)
        _ = try await feed.watchNext("id2")
        XCTAssertEqual(music.nextCalls, 2)
    }

    func testWhatIsTrendingIsAskedForOnceForHours() async throws {
        let clock = Clock()
        let music = FakeMusic()
        let feed = feed(music, FakeLrclib(nil), clock)
        let first = try await feed.trending()
        XCTAssertEqual(first.first?.title, "Hits in en")
        clock.time += MusicFeed.trendingMs - 1
        _ = try await feed.trending()
        XCTAssertEqual(music.trendingCalls.count, 1)
        clock.time += 1
        _ = try await feed.trending()
        XCTAssertEqual(music.trendingCalls.count, 2)
    }

    func testTrendingIsAskedAgainWhenTheLanguageChangesAndNotShownInTheWrongOne() async throws {
        let music = FakeMusic()
        let feed = feed(music, FakeLrclib(nil))
        let english = try await feed.trending("en")
        XCTAssertEqual(english.first?.title, "Hits in en")
        let vietnamese = try await feed.trending("vi")
        XCTAssertEqual(vietnamese.first?.title, "Hits in vi")
        _ = try await feed.trending("vi")
        XCTAssertEqual(music.trendingCalls, ["en", "vi"])
    }

    func testASearchAsksForSongsOrForVideos() async throws {
        let feed = feed(FakeMusic(), FakeLrclib(nil))
        let songs = try await feed.search("q", songs: true)
        XCTAssertEqual(songs.first?.videoId, "song")
        let videos = try await feed.search("q", songs: false)
        XCTAssertEqual(videos.first?.videoId, "clip")
    }

    func testTheStoreKeepsOnlyTheNewestFilesAndSurvivesADamagedOne() throws {
        let store = LyricsStore(dir: dir, maxEntries: 2)
        store.putFound("a", Lyrics(lines: [], plain: "x"))
        store.putFound("b", Lyrics(lines: [], plain: "x"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: dir.appendingPathComponent("a.json").path)
        store.putFound("c", Lyrics(lines: [], plain: "x"))
        XCTAssertNil(store.get("a"))
        XCTAssertEqual(store.get("b"), .found(Lyrics(lines: [], plain: "x")))

        try "{ cut off".write(to: dir.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(store.get("b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.json").path))
    }

    func testANameFromOutsideCannotPointOutOfTheFolder() throws {
        let store = LyricsStore(dir: dir)
        store.putFound("../../evil", Lyrics(lines: [], plain: "x"))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(store.get("../../evil"), .found(Lyrics(lines: [], plain: "x")))
    }
}

final class YoutubeLinksTests: XCTestCase {
    func testFindsTheVideoInTheUsualLinkShapes() {
        let id = "bNp9pn0ni3I"
        XCTAssertEqual(YoutubeLinks.videoId("https://www.youtube.com/watch?v=\(id)"), id)
        XCTAssertEqual(YoutubeLinks.videoId("https://music.youtube.com/watch?v=\(id)&si=abc"), id)
        XCTAssertEqual(YoutubeLinks.videoId("https://m.youtube.com/watch?feature=share&v=\(id)"), id)
        XCTAssertEqual(YoutubeLinks.videoId("https://youtu.be/\(id)?t=42"), id)
        XCTAssertEqual(YoutubeLinks.videoId("https://www.youtube.com/shorts/\(id)"), id)
        XCTAssertEqual(YoutubeLinks.videoId(id), id)
    }

    func testSearchWordsAreNotMistakenForAVideoId() {
        XCTAssertNil(YoutubeLinks.videoId("Radioactive"))
        XCTAssertNil(YoutubeLinks.videoId("son tung mtp"))
        XCTAssertNil(YoutubeLinks.videoId("https://example.com/watch?v=short"))
    }

    func testAPlaylistPageGivesItsIdButAVideoInsideAPlaylistDoesNot() {
        let list = "PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf"
        XCTAssertEqual(YoutubeLinks.playlistId("https://www.youtube.com/playlist?list=\(list)"), list)
        XCTAssertEqual(YoutubeLinks.playlistId("https://music.youtube.com/playlist?list=\(list)&si=x"), list)
        XCTAssertNil(YoutubeLinks.playlistId("https://www.youtube.com/watch?v=bNp9pn0ni3I&list=\(list)"))
        XCTAssertEqual(YoutubeLinks.videoId("https://www.youtube.com/watch?v=bNp9pn0ni3I&list=\(list)"), "bNp9pn0ni3I")
    }
}
