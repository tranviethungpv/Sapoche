import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SapocheCore

@MainActor
final class FakePlatform: PlatformServices {
    var deviceModel = "iPhone"
    var isMetered = false
    let calm = StateFlow<Bool>(false)
    let output = StateFlow<AudioOutput>(AudioOutput(kind: "speaker", name: ""))
    let volume = StateFlow<Float>(1)
    var outputPicked = 0
    var shared: [String] = []
    var exported: [(String, String)] = []
    var toImport: String?

    /// The folder with the music, what the tags of each file in it say, and what the person picks to copy in.
    var musicFolder = FileManager.default.temporaryDirectory.appendingPathComponent("music-\(UUID().uuidString)")
    var tags: [String: MusicTags] = [:]
    var covers: [String: Data] = [:]
    var picked: [URL] = []

    init() {
        try? FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)
    }

    func musicTags(_ url: URL) async -> MusicTags? { tags[url.lastPathComponent] }

    func musicCover(_ url: URL) async -> Data? { covers[url.lastPathComponent] }

    func pickMusicFiles() async throws -> [URL] { picked }

    func pickOutput() { outputPicked += 1 }

    func setVolume(_ level: Float) { volume.set(level) }

    func share(_ text: String) { shared.append(text) }

    func exportFile(name: String, contents: String) async throws -> Bool {
        exported.append((name, contents))
        return true
    }

    func importFile() async throws -> String? { toImport }

    /// What the phone says of notifications, whether the person gives leave when asked, and what was shown.
    var noticeAnswer = "undecided"
    var noticeLeave = true
    var noticesShown: [(room: String, title: String, body: String)] = []
    var noticesCleared = 0

    func noticePermission() async -> String { noticeAnswer }

    func askForNotices() async -> Bool {
        noticeAnswer = noticeLeave ? "granted" : "denied"
        return noticeLeave
    }

    func showNotice(room: String, title: String, body: String) { noticesShown.append((room, title, body)) }

    func clearNotices() { noticesCleared += 1 }

    func whileInBackground(_ work: @escaping () async -> Void) async { await work() }
}

@MainActor
final class FakeSocket: Socket {
    var sent: [String] = []
    var cancelled = false
    let events: SocketEvents
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String], events: SocketEvents) {
        self.url = url
        self.headers = headers
        self.events = events
    }

    func send(_ text: String) -> Bool {
        sent.append(text)
        return true
    }

    func cancel() { cancelled = true }
    func close(code: Int, reason: String) { cancelled = true }

    /// What the server does.
    func open() { events.socketOpened() }
    func receive(_ text: String) { events.socketMessage(text) }
}

@MainActor
final class FakeSockets: SocketFactory {
    var opened: [FakeSocket] = []

    func open(url: URL, headers: [String: String], events: SocketEvents) -> Socket {
        let socket = FakeSocket(url: url, headers: headers, events: events)
        opened.append(socket)
        return socket
    }
}

final class FakeResolver: StreamResolver, @unchecked Sendable {
    var results: [TrackInfo] = [TrackInfo(videoId: "vid00000001", title: "Found", artist: "Someone", thumbUrl: nil, durationSec: 200)]
    var asked: [String] = []

    func search(_ query: String, limit: Int, songsOnly: Bool) async throws -> [TrackInfo] {
        asked.append("search \(query) songs=\(songsOnly)")
        return results
    }

    func resolve(_ videoId: String) async throws -> Resolved {
        let track = TrackInfo(videoId: videoId, title: "Resolved \(videoId)", artist: "A", thumbUrl: nil, durationSec: 200)
        let source = AudioSource(url: "https://example.invalid/\(videoId)", mimeType: "audio/mp4", bitrateKbps: 128, contentLength: 10, itag: 140)
        return Resolved(track: track, best: source, all: [source], userAgent: "test-agent")
    }

    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistRef] {
        [PlaylistRef(id: "PLabc", title: "Mix", uploader: "Me", thumbUrl: nil, songCount: 3)]
    }

    func playlist(_ playlistId: String, limit: Int) async throws -> Playlist {
        Playlist(title: "Listed", tracks: results)
    }

    func related(_ videoId: String, limit: Int) async throws -> [TrackInfo] { results }
    func suggest(_ query: String) async throws -> [String] { ["\(query) one", "\(query) two"] }
}

/// Writes ten bytes wherever it is asked to, like a transfer that worked.
struct FakeFetcher: FileFetcher {
    func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
        try Data(repeating: 7, count: 10).write(to: file)
        return 10
    }
}

@MainActor
final class BridgeTests: XCTestCase {
    private var time: VirtualTime!
    private var dir: URL!
    private var engine: FakePlayer!
    private var platform: FakePlatform!
    private var sockets: FakeSockets!
    private var prefs: MemoryStore!
    private var controller: GroupController!
    private var bridge: Bridge!
    private var resolver: FakeResolver!
    private var http: FakeHTTP!
    private var events: [[String: Any]] = []
    private var libraryChanges = Counter()

    override func setUp() async throws {
        time = VirtualTime()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = FakePlayer(time: time)
        platform = FakePlatform()
        sockets = FakeSockets()
        prefs = MemoryStore()
        resolver = FakeResolver()
        http = FakeHTTP()
        events = []
        let changes = libraryChanges
        let store = try LibraryStore(path: ":memory:", onChange: { [weak self] in
            changes.bump()
            Task { @MainActor in self?.bridge?.libraryChanged() }
        })
        let streams = StreamCache(resolver: resolver)
        let files = MediaFiles(downloadsDir: dir.appendingPathComponent("d"), playDir: dir.appendingPathComponent("p"), playLimitBytes: 1 << 20)
        let media = MediaLibrary(files: files, streams: streams, fetcher: FakeFetcher())
        let music = MusicFeed(music: MusicClient { _, _ in JSON.parse("{}")! }, lyricsClient: LyricsClient { _ in nil }, lyricsStore: LyricsStore(dir: dir.appendingPathComponent("l")))
        let suggestions = SuggestionFeed(store: store, resolver: resolver, music: music)
        let downloader = Downloader(store: store, fetch: { try await media.download($0) })
        let prefs = prefs!
        controller = GroupController(engine: engine, prefs: prefs, queueFile: QueueFile(url: dir.appendingPathComponent("queue.json")),
                                     config: { ServerConfig.load(prefs) }, time: time, sockets: sockets)
        bridge = Bridge(controller: controller, prefs: prefs, platform: platform, store: store, resolver: resolver, streams: streams,
                        music: music, suggestions: suggestions, media: media, files: files, downloader: downloader, http: http, time: time)
        bridge.start { [weak self] text in
            if let object = JSON.parse(text)?.object { self?.events.append(object) }
        }
        bridge.setVisible(true)
    }

    override func tearDown() async throws {
        bridge.stop()
        controller.release()
        try? FileManager.default.removeItem(at: dir)
    }

    private func call(_ method: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await bridge.handle(method, args)
    }

    /// The answer to a command, as the kind of value the screen expects.
    private func result<T>(_ method: String, _ args: [String: Any] = [:], as type: T.Type) async throws -> T {
        let answer = try await bridge.handle(method, args)
        return try XCTUnwrap(answer as? T, "\(method) gave \(String(describing: answer))")
    }

    private func song(_ n: Int) -> [String: Any] {
        ["videoId": "video00000\(n)", "title": "Song \(n)", "artist": "Artist", "thumb": NSNull(), "durMs": 200_000]
    }

    private func states() -> [[String: Any]] { events.filter { $0["type"] as? String == "state" } }

    /// Lets the library and the other actors answer.
    private func settle() async {
        for _ in 0..<20 {
            await time.settle()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // ------------------------------------------------------------------ music on this phone

    private func addMusic(_ name: String, durMs: Int64 = 60_000, title: String? = nil, artist: String? = nil) throws {
        try Data([1, 2, 3]).write(to: platform.musicFolder.appendingPathComponent(name))
        platform.tags[name] = MusicTags(title: title, artist: artist, album: nil, durMs: durMs)
    }

    func testTheMusicOnThePhoneNeedsNoPermissionAndIsOnByDefault() async throws {
        let status = try await result("localStatus", as: [String: Any].self)
        XCTAssertEqual(status["enabled"] as? Bool, true)
        XCTAssertEqual(status["access"] as? String, "granted")
        XCTAssertEqual(status["count"] as? Int, 0)
        let access = try await result("localAccess", as: String.self)
        XCTAssertEqual(access, "granted")

        _ = try await call("localEnable", ["on": false])
        let off = try await result("localStatus", as: [String: Any].self)
        XCTAssertEqual(off["enabled"] as? Bool, false)
        _ = try await call("localEnable", ["on": true])
        let on = try await result("localStatus", as: [String: Any].self)
        XCTAssertEqual(on["enabled"] as? Bool, true)
    }

    func testAScanListsWhatIsInTheFolderAndTheListIsReadBack() async throws {
        try addMusic("one.mp3", title: "One", artist: "Ann")
        try addMusic("two.flac", title: "Two")
        try addMusic("a.ogg")
        let scan = try await result("localScan", as: [String: Any].self)
        XCTAssertEqual(scan["total"] as? Int, 2)
        XCTAssertEqual(scan["unsupported"] as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: platform.musicFolder.appendingPathComponent(MusicFolder.helpName).path))

        let songs = try await result("localTracks", as: [[String: Any]].self)
        XCTAssertEqual(Set(songs.compactMap { $0["title"] as? String }), ["One", "Two"])
        let one = try XCTUnwrap(songs.first { $0["title"] as? String == "One" })
        XCTAssertEqual(one["artist"] as? String, "Ann")
        XCTAssertEqual(one["mime"] as? String, "audio/mpeg")
        XCTAssertEqual(one["missing"] as? Bool, false)
        XCTAssertTrue((one["videoId"] as? String ?? "").hasPrefix("local:"))
        XCTAssertTrue((one["thumb"] as? String ?? "").hasPrefix("sapoche-local:"))
        let status = try await result("localStatus", as: [String: Any].self)
        XCTAssertEqual(status["count"] as? Int, 2)
    }

    func testAFileTakenOutOfTheFolderIsMissingOnlyWhileSomethingPointsToIt() async throws {
        try addMusic("one.mp3", title: "One")
        try addMusic("two.mp3", title: "Two")
        _ = try await call("localScan")
        let songs = try await result("localTracks", as: [[String: Any]].self)
        let one = try XCTUnwrap(songs.first { $0["title"] as? String == "One" })
        _ = try await call("libraryLike", one.merging(["on": true]) { $1 })
        try FileManager.default.removeItem(at: platform.musicFolder.appendingPathComponent("one.mp3"))
        try FileManager.default.removeItem(at: platform.musicFolder.appendingPathComponent("two.mp3"))
        _ = try await call("localScan")
        let left = try await result("localTracks", as: [[String: Any]].self)
        XCTAssertEqual(left.map { $0["title"] as? String }, ["One"])
        XCTAssertEqual(left.first?["missing"] as? Bool, true)
        let status = try await result("localStatus", as: [String: Any].self)
        XCTAssertEqual(status["count"] as? Int, 0)
        XCTAssertEqual(status["missing"] as? [String], [one["videoId"] as? String ?? ""])
    }

    func testTheCoverInsideAFileIsAskedForByTheSong() async throws {
        try addMusic("one.mp3", title: "One")
        platform.covers["one.mp3"] = Data([9, 9])
        _ = try await call("localScan")
        let listed = try await result("localTracks", as: [[String: Any]].self)
        let id = try XCTUnwrap(listed.first?["videoId"] as? String)
        let cover = try await call("localCover", ["videoId": id])
        XCTAssertEqual(cover as? Data, Data([9, 9]))
        let none = try await call("localCover", ["videoId": "local:ffffffffffffffff"])
        XCTAssertNil(none)
    }

    func testFilesThePersonPicksAreCopiedIntoTheFolder() async throws {
        let picked = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString).mp3")
        try Data([1]).write(to: picked)
        defer { try? FileManager.default.removeItem(at: picked) }
        platform.picked = []
        let nothing = try await call("localImport")
        XCTAssertNil(nothing, "backing out gives nothing")
        platform.picked = [picked]
        let copied = try await call("localImport")
        XCTAssertEqual(copied as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: platform.musicFolder.appendingPathComponent(picked.lastPathComponent).path))
    }

    func testABackupSaysHowManySongsFromThisPhoneItLeftOut() async throws {
        try addMusic("one.mp3", title: "One")
        _ = try await call("localScan")
        let listed = try await result("localTracks", as: [[String: Any]].self)
        let one = try XCTUnwrap(listed.first)
        _ = try await call("libraryLike", one.merging(["on": true]) { $1 })
        _ = try await call("libraryLike", song(1).merging(["on": true]) { $1 })
        let saved = try await result("backupExport", as: [String: Any].self)
        XCTAssertEqual(saved["liked"] as? Int, 1)
        XCTAssertEqual(saved["local"] as? Int, 1)
    }

    func testTheProfileTellsWhatTheUIAsksFor() async throws {
        let profile = try await result("profile", as: [String: Any].self)
        XCTAssertNil(profile["name"], "the name of the phone is not offered to the room")
        XCTAssertEqual(profile["device"] as? String, "iPhone")
        XCTAssertEqual(profile["autoplay"] as? Bool, true)
        XCTAssertEqual(profile["configured"] as? Bool, false)
        XCTAssertEqual(profile["server"] as? String, "")

        _ = try await call("configure", ["server": " sapoche.example.dev/ "])
        _ = try await call("configure", ["key": "secret"])
        let again = try await result("profile", as: [String: Any].self)
        XCTAssertEqual(again["server"] as? String, "https://sapoche.example.dev")
        XCTAssertEqual(again["configured"] as? Bool, true)
        XCTAssertEqual(again["key"] as? Bool, true)
        XCTAssertNil(again["secret"])
    }

    func testTheProfileSaysWhenTheLibraryCouldNotBeOpened() async throws {
        let profile = try await result("profile", as: [String: Any].self)
        XCTAssertNil(profile["libraryLost"], "a library that opened says nothing")
        bridge.libraryOpened = false
        let lost = try await result("profile", as: [String: Any].self)
        XCTAssertEqual(lost["libraryLost"] as? Bool, true)
    }

    func testTheAudioQualityIsKeptAndTold() async throws {
        let first = try await result("profile", as: [String: Any].self)
        XCTAssertEqual(first["audioQuality"] as? Int, 3, "the best until the person chooses")
        _ = try await call("setAudioQuality", ["level": 1])
        let chosen = try await result("profile", as: [String: Any].self)
        XCTAssertEqual(chosen["audioQuality"] as? Int, 1)
        XCTAssertEqual(prefs.int64("audio_quality"), 1)
        _ = try await call("setAudioQuality", ["level": 42])
        let unknown = try await result("profile", as: [String: Any].self)
        XCTAssertEqual(unknown["audioQuality"] as? Int, 3, "a level nobody knows is the best")
    }

    func testTheMoodsAndTheChartsAreAskedFor() async throws {
        let home = try await result("musicHome", ["params": "ggM8abc"], as: [String: Any].self)
        XCTAssertEqual((home["chips"] as? [Any])?.count, 0)
        XCTAssertEqual((home["shelves"] as? [Any])?.count, 0)
        let plain = try await result("musicHome", as: [String: Any].self)
        XCTAssertNotNil(plain["chips"])
        let charts = try await result("musicCharts", as: [Any].self)
        XCTAssertTrue(charts.isEmpty)
    }

    func testTheFirstStateIsSentWhenTheScreenListens() async throws {
        let first = try XCTUnwrap(states().first)
        XCTAssertEqual(first["phase"] as? String, "idle")
        XCTAssertTrue(first["room"] is NSNull)
        XCTAssertEqual((first["queue"] as? [Any])?.count, 0)
    }

    func testAddingASongOutsideARoomPlaysItAndTellsTheScreen() async throws {
        _ = try await call("add", song(1))
        await time.advance(100)
        XCTAssertEqual(engine.loaded?.title, "Song 1")
        XCTAssertTrue(engine.playing)
        let state = try XCTUnwrap(states().last)
        XCTAssertEqual(state["phase"] as? String, "paused", "outside a room whether it plays is the player's business")
        let queue = try XCTUnwrap(state["queue"] as? [[String: Any]])
        XCTAssertEqual(queue.map { $0["title"] as? String }, ["Song 1"])
        XCTAssertEqual(state["index"] as? Int, 0)
        XCTAssertTrue(state["room"] is NSNull)

        _ = try await call("addMany", ["tracks": [song(2), song(3)], "next": false])
        await time.advance(100)
        let queued = try XCTUnwrap(states().last?["queue"] as? [[String: Any]])
        XCTAssertEqual(queued.count, 3)
        _ = try await call("pause")
        XCTAssertFalse(engine.playing)
        _ = try await call("next")
        await time.advance(100)
        XCTAssertEqual(engine.loaded?.title, "Song 2")
    }

    func testThePositionIsSentWhileTheScreenIsOn() async throws {
        _ = try await call("add", song(1))
        await time.advance(2500)
        let positions = events.filter { $0["type"] as? String == "position" }
        XCTAssertFalse(positions.isEmpty)
        let last = try XCTUnwrap(positions.last)
        XCTAssertEqual(last["playing"] as? Bool, true)
        XCTAssertGreaterThan(JSON(last["positionMs"]).int64 ?? 0, 1000)
        XCTAssertEqual(JSON(last["durationMs"]).int64, 200_000)
    }

    func testTheCacheFolderIsNamed() async throws {
        let folder = try await call("cacheFolder") as? String
        XCTAssertFalse(folder?.isEmpty ?? true)
    }

    func testNoPositionIsSentWhileTheSongStandsStill() async throws {
        _ = try await call("add", song(1))
        await time.advance(1500)
        _ = try await call("pause")
        await time.advance(100)
        let paused = events.filter { $0["type"] as? String == "position" }.count
        await time.advance(5000)
        XCTAssertEqual(events.filter { $0["type"] as? String == "position" }.count, paused)
    }

    func testNothingIsSentWhileTheScreenIsOff() async throws {
        bridge.setVisible(false)
        let before = events.count
        _ = try await call("add", song(1))
        await time.advance(3000)
        XCTAssertEqual(events.count, before)
        bridge.setVisible(true)
        XCTAssertEqual(states().last?["queue"].flatMap { ($0 as? [Any])?.count }, 1, "the screen catches up when it returns")
    }

    func testSearchAndSuggestionsAndLookupGoToYouTube() async throws {
        let found = try await result("search", ["query": " lofi ", "songsOnly": true], as: [[String: Any]].self)
        XCTAssertEqual(found.first?["title"] as? String, "Found")
        XCTAssertEqual(JSON(found.first?["durMs"]).int64, 200_000)
        XCTAssertEqual(resolver.asked, ["search lofi songs=true"])
        let blank = try await call("search", ["query": "  "]) as? [Any]
        XCTAssertEqual(blank?.count, 0)

        let words = try await result("suggest", ["query": "lofi"], as: [String].self)
        XCTAssertEqual(words, ["lofi one", "lofi two"])

        let video = try await result("lookup", ["text": "https://youtu.be/bNp9pn0ni3I"], as: [String: Any].self)
        XCTAssertEqual((video["tracks"] as? [[String: Any]])?.first?["title"] as? String, "Resolved bNp9pn0ni3I")
        let list = try await result("lookup", ["text": "https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf"], as: [String: Any].self)
        XCTAssertEqual(list["title"] as? String, "Listed")
        let words2 = try await call("lookup", ["text": "just words"])
        XCTAssertNil(words2)
        let lists = try await result("searchPlaylists", ["query": "mix"], as: [[String: Any]].self)
        XCTAssertEqual(lists.first?["id"] as? String, "PLabc")
        XCTAssertEqual(JSON(lists.first?["count"]).int, 3)
    }

    func testLikesHistoryAndPlaylistsAreKeptAndTheScreenIsTold() async throws {
        _ = try await call("libraryLike", song(1).merging(["on": true]) { $1 })
        let liked = try await result("libraryLiked", as: [[String: Any]].self)
        XCTAssertEqual(liked.map { $0["videoId"] as? String }, ["video000001"])
        XCTAssertTrue(events.contains { $0["type"] as? String == "library" })

        let id = try await result("playlistCreate", ["name": "Road", "tracks": [song(1), song(2)]], as: Int64.self)
        _ = try await call("playlistAdd", ["id": id, "tracks": [song(2), song(3)]])
        let tracks = try await result("playlistTracks", ["id": id], as: [[String: Any]].self)
        XCTAssertEqual(tracks.count, 3)
        _ = try await call("playlistMove", ["id": id, "videoId": "video000003", "to": 0])
        _ = try await call("playlistRename", ["id": id, "name": "Trip"])
        let lists = try await result("playlists", as: [[String: Any]].self)
        XCTAssertEqual(lists.first?["name"] as? String, "Trip")
        XCTAssertEqual(lists.first?["count"] as? Int, 3)
        _ = try await call("playlistRemove", ["id": id, "videoId": "video000001"])
        _ = try await call("playlistDelete", ["id": id])
        let none = try await result("playlists", as: [Any].self)
        XCTAssertEqual(none.count, 0)
    }

    func testBackupExportAndImportGoThroughTheFilePicker() async throws {
        _ = try await call("libraryLike", song(1).merging(["on": true]) { $1 })
        let counts = try await result("backupExport", as: [String: Any].self)
        XCTAssertEqual(counts["liked"] as? Int, 1)
        let (name, text) = try XCTUnwrap(platform.exported.first)
        XCTAssertTrue(name.hasPrefix("sapoche-library-") && name.hasSuffix(".json"))
        XCTAssertTrue(text.contains("\"app\":\"sapoche\""))

        platform.toImport = text
        let restored = try await result("backupImport", as: [String: Any].self)
        XCTAssertEqual(restored["liked"] as? Int, 0, "restoring what is already there changes nothing")
        platform.toImport = "not a backup"
        do {
            _ = try await call("backupImport")
            XCTFail("expected a refusal")
        } catch let error as BridgeError {
            XCTAssertEqual(error.message, "Not a Sapoche backup")
        }
        platform.toImport = nil
        let cancelled = try await call("backupImport")
        XCTAssertNil(cancelled)
    }

    func testADownloadIsQueuedFetchedAndListed() async throws {
        let answer = try await call("download", ["tracks": [song(1)], "allowMetered": false]) as? String
        XCTAssertEqual(answer, "queued")
        await settle()
        let list = try await result("downloads", as: [[String: Any]].self)
        XCTAssertEqual(list.first?["state"] as? String, "done")
        XCTAssertEqual(JSON(list.first?["bytes"]).int64, 10)
        let storage = try await result("storage", as: [String: Any].self)
        XCTAssertEqual(storage["downloadCount"] as? Int, 1)
        XCTAssertEqual(JSON(storage["downloadBytes"]).int64, 10)
        XCTAssertEqual(storage["playLimitMb"] as? Int, 256)

        _ = try await call("downloadRemove", ["videoId": "video000001"])
        let empty = try await result("downloads", as: [Any].self)
        XCTAssertEqual(empty.count, 0)
    }

    func testMobileDataIsAskedAboutBeforeDownloading() async throws {
        platform.isMetered = true
        let answer = try await call("download", ["tracks": [song(1)], "allowMetered": false]) as? String
        XCTAssertEqual(answer, "metered")
        let forced = try await call("download", ["tracks": [song(1)], "allowMetered": true]) as? String
        XCTAssertEqual(forced, "queued")
    }

    func testTheSleepTimerIsSentToTheScreen() async throws {
        _ = try await call("sleep", ["mode": "time", "minutes": 10])
        let sleeps = events.filter { $0["type"] as? String == "sleep" }
        XCTAssertEqual(sleeps.last?["mode"] as? String, "time")
        XCTAssertNotNil(sleeps.last?["endsAt"] as? Int64)
        _ = try await call("sleep", ["mode": "off"])
        XCTAssertEqual(events.filter { $0["type"] as? String == "sleep" }.last?["mode"] as? String, "off")
    }

    func testTheScreenIsToldWhereTheSoundGoesAndCanOpenTheList() async throws {
        let outputs = { self.events.filter { $0["type"] as? String == "output" } }
        XCTAssertEqual(outputs().last?["kind"] as? String, "speaker")
        platform.output.set(AudioOutput(kind: "bluetooth", name: "AirPods Pro"))
        XCTAssertEqual(outputs().last?["kind"] as? String, "bluetooth")
        XCTAssertEqual(outputs().last?["name"] as? String, "AirPods Pro")
        _ = try await call("pickOutput")
        XCTAssertEqual(platform.outputPicked, 1)
    }

    func testTheVolumeIsToldAndSetFromTheScreen() async throws {
        let levels = { self.events.filter { $0["type"] as? String == "volume" } }
        XCTAssertEqual(levels().last?["level"] as? Double, 1)
        platform.volume.set(0.25) // the buttons of the phone
        XCTAssertEqual(levels().last?["level"] as? Double, 0.25)
        _ = try await call("setVolume", ["level": 0.5])
        XCTAssertEqual(platform.volume.value, 0.5)
        XCTAssertEqual(levels().last?["level"] as? Double, 0.5)
    }

    func testARoomCannotBeEnteredBeforeTheServerIsSet() async throws {
        do {
            _ = try await call("join", ["code": "ABC234", "name": "Me"])
            XCTFail("expected a refusal")
        } catch let error as BridgeError {
            XCTAssertEqual(error.code, "not_configured")
        }
        do {
            _ = try await call("createRoom", ["name": "Me"])
            XCTFail("expected a refusal")
        } catch let error as BridgeError {
            XCTAssertEqual(error.code, "not_configured")
        }
        do {
            _ = try await call("kick", ["id": "x"])
            XCTFail("expected a refusal")
        } catch is GroupController.NoRoom {
            // not in a room
        }
    }

    func testCreatingAndJoiningARoomFollowsTheServer() async throws {
        _ = try await call("configure", ["server": "https://sapoche.example.dev", "key": "k3y"])
        http.answer("/rooms", text: #"{"code":"ABC234"}"#)
        let code = try await call("createRoom", ["name": "Me"]) as? String
        XCTAssertEqual(code, "ABC234")
        let created = try XCTUnwrap(http.calls.first { $0.url.hasSuffix("/rooms") })
        XCTAssertEqual(created.headers["x-sapoche-key"], "k3y")

        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        XCTAssertEqual(socket.url.absoluteString, "wss://sapoche.example.dev/room/ABC234")
        XCTAssertEqual(socket.headers["X-Sapoche-Key"], "k3y")
        socket.open()
        let join = try XCTUnwrap(JSON.parse(socket.sent.first ?? "")?.object)
        XCTAssertEqual(join["t"] as? String, "join")
        XCTAssertEqual(join["name"] as? String, "Me")
        XCTAssertEqual(join["create"] as? Bool, true)

        let room = #"""
        {"t":"state","serverNow":1000,"you":"dev-a","protocol":6,
         "state":{"queue":[{"id":"q1","videoId":"video000001","title":"Song 1","artist":"A","durMs":200000,"addedBy":"dev-a"}],
                  "index":0,"phase":"paused","startedAt":0,"positionMs":0,"epoch":2,"repeat":"off","name":"Party","ownerId":"dev-a","guestControl":"all","autoplay":true,"shuffle":false},
         "members":[{"id":"dev-a","name":"Me","ready":true,"owner":true}]}
        """#
        socket.receive(room.replacingOccurrences(of: "\n", with: ""))
        await time.advance(100)
        let state = try XCTUnwrap(states().last)
        XCTAssertEqual(state["room"] as? String, "ABC234")
        XCTAssertEqual(state["name"] as? String, "Party")
        XCTAssertEqual(state["ownerId"] as? String, "dev-a")
        XCTAssertEqual(state["roomAutoplay"] as? Bool, true)
        XCTAssertEqual(state["shuffle"] as? Bool, false, "in a room the room's shuffle")
        XCTAssertEqual(state["connection"] as? String, "connected")
        XCTAssertEqual((state["queue"] as? [[String: Any]])?.first?["id"] as? String, "q1")
        XCTAssertEqual((state["members"] as? [[String: Any]])?.first?["owner"] as? Bool, true)

        // In a room the buttons go to the room
        socket.sent.removeAll()
        _ = try await call("play")
        _ = try await call("seek", ["ms": 5000])
        _ = try await call("roomName", ["name": "New"])
        _ = try await call("roomTheme", ["theme": "ocean", "bg": ""])
        _ = try await call("roomAutoplay", ["on": false])
        _ = try await call("setShuffle", ["on": true])
        XCTAssertEqual(socket.sent.compactMap { JSON.parse($0)?.at("t").string }, ["play", "seek", "room.name", "room.theme", "autoplay", "shuffle"])
        XCTAssertEqual(JSON.parse(socket.sent.last ?? "")?.at("on").bool, true)

        // The room tells this phone to get ready, then to start
        socket.receive(#"{"t":"prepare","epoch":3,"index":0,"item":{"id":"q1","videoId":"video000001","title":"Song 1","artist":"A","durMs":200000,"addedBy":"dev-a"},"seekToMs":0}"#)
        await settle()
        XCTAssertEqual(engine.loaded?.id, "q1")
        XCTAssertTrue(socket.sent.contains { $0.contains("\"ready\"") && $0.contains("\"epoch\":3") })

        _ = try await call("leave")
        XCTAssertTrue(socket.sent.contains { $0.contains("\"bye\"") })
        await time.advance(100)
        XCTAssertTrue(states().last?["room"] is NSNull)
    }

    func testTheSpeedIsChosenOutsideARoomAndTheScreenIsTold() async throws {
        _ = try await call("add", song(1))
        await time.advance(100)
        XCTAssertEqual(JSON(states().last?["playbackSpeed"]).double, 1)
        _ = try await call("playbackSpeed", ["speed": 1.5])
        XCTAssertEqual(engine.currentSpeed, 1.5)
        XCTAssertEqual(JSON(states().last?["playbackSpeed"]).double, 1.5)
        await time.advance(1500)
        let position = events.last { $0["type"] as? String == "position" }
        XCTAssertEqual(JSON(position?["speed"]).double, 1.5, "the screen moves its bar at the speed the song plays at")
        // No faster or slower than a person can choose
        _ = try await call("playbackSpeed", ["speed": 9.0])
        XCTAssertEqual(engine.currentSpeed, 2)
        _ = try await call("playbackSpeed", ["speed": 0.01])
        XCTAssertEqual(engine.currentSpeed, 0.25)
    }

    func testARoomPlaysAtNormalSpeedAndItsSpeedIsNotThePersonsToChange() async throws {
        _ = try await call("add", song(1))
        await time.advance(100)
        _ = try await call("playbackSpeed", ["speed": 1.75])
        XCTAssertEqual(engine.currentSpeed, 1.75)

        _ = try await call("configure", ["server": "https://sapoche.example.dev", "key": "k3y"])
        http.answer("/rooms", text: #"{"code":"ABC234"}"#)
        _ = try await call("createRoom", ["name": "Me"])
        await time.advance(10)
        XCTAssertEqual(engine.currentSpeed, 1, "joining puts the speed back to normal")
        XCTAssertEqual(JSON(states().last?["playbackSpeed"]).double, 1)
        _ = try await call("playbackSpeed", ["speed": 1.5])
        XCTAssertEqual(engine.currentSpeed, 1)
        XCTAssertEqual(JSON(states().last?["playbackSpeed"]).double, 1)

        // Back on the personal queue it stays normal until chosen again
        _ = try await call("leave")
        await time.advance(100)
        XCTAssertEqual(engine.currentSpeed, 1)
        _ = try await call("playbackSpeed", ["speed": 1.25])
        XCTAssertEqual(engine.currentSpeed, 1.25)
    }

    func testWatchingThePictureAndTheSmallWindowGoToThePlayer() async throws {
        let without = try await call("pipSupported") as? Bool
        XCTAssertEqual(without, false)
        engine.pipSupported = true
        let with = try await call("pipSupported") as? Bool
        XCTAssertEqual(with, true)
        _ = try await call("videoWatching", ["on": true, "width": 720, "height": 1280])
        _ = try await call("videoWatching", ["on": false, "width": 720, "height": 1280])
        XCTAssertEqual(engine.watching, ["true 720x1280", "false 720x1280"])
        _ = try await call("pipEnter")
        XCTAssertEqual(engine.pipStarts, 1)
    }

    // ------------------------------------------------------------------ notices of the chat while the screen is off

    /// The phone is in room ABC234 as "me", and the screen is off.
    private func inRoomWithTheScreenOff() async throws -> FakeSocket {
        _ = try await call("configure", ["server": "https://sapoche.example.dev"])
        _ = try await call("join", ["code": "abc234", "name": "Me"])
        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        socket.open()
        socket.receive(#"{"t":"state","serverNow":1,"you":"me","protocol":13,"state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":1},"members":[{"id":"u2","name":"Ann","ready":true}]}"#)
        await time.advance(10)
        bridge.setVisible(false)
        return socket
    }

    func testNoticesAreOffUntilThePersonTurnsThemOn() async throws {
        let info = try await result("notifications", as: [String: Any].self)
        XCTAssertEqual(info["supported"] as? Bool, true)
        XCTAssertEqual(info["enabled"] as? Bool, false)
        XCTAssertEqual(info["permission"] as? String, "undecided")
        XCTAssertEqual(info["preview"] as? Bool, true)

        let socket = try await inRoomWithTheScreenOff()
        socket.receive(#"{"t":"chat","msg":{"id":1,"by":"u2","name":"Ann","text":"hello","at":5}}"#)
        await settle()
        XCTAssertTrue(platform.noticesShown.isEmpty)
    }

    func testTurningThemOnAsksTheSystemAndAnswersWithHowThingsStand() async throws {
        platform.noticeLeave = false
        let refused = try await result("setNotifications", ["on": true], as: [String: Any].self)
        XCTAssertEqual(refused["enabled"] as? Bool, false)
        XCTAssertEqual(refused["permission"] as? String, "denied")

        platform.noticeLeave = true
        platform.noticeAnswer = "undecided"
        let given = try await result("setNotifications", ["on": true], as: [String: Any].self)
        XCTAssertEqual(given["enabled"] as? Bool, true)
        XCTAssertEqual(given["permission"] as? String, "granted")

        let off = try await result("setNotifications", ["on": false], as: [String: Any].self)
        XCTAssertEqual(off["enabled"] as? Bool, false)
        XCTAssertGreaterThan(platform.noticesCleared, 0)
    }

    func testAMessageWhileTheScreenIsOffIsShownAsANotice() async throws {
        _ = try await call("setNotifications", ["on": true])
        let socket = try await inRoomWithTheScreenOff()
        socket.receive(#"{"t":"chat","msg":{"id":1,"by":"u2","name":"Ann","text":"hello","at":5}}"#)
        socket.receive(#"{"t":"chat","msg":{"id":2,"by":"me","name":"Me","text":"mine","at":6}}"#)
        await settle()
        XCTAssertEqual(platform.noticesShown.count, 1, "this phone's own message is no news")
        XCTAssertEqual(platform.noticesShown.first?.room, "ABC234")
        XCTAssertEqual(platform.noticesShown.first?.title, "Ann")
        XCTAssertEqual(platform.noticesShown.first?.body, "hello")

        _ = try await call("setNotificationPreview", ["on": false])
        socket.receive(#"{"t":"chat","msg":{"id":3,"by":"u2","name":"Ann","text":"secret","at":7}}"#)
        await settle()
        XCTAssertEqual(platform.noticesShown.last?.body, "sent a message")
    }

    func testNothingIsShownWhileTheScreenIsOnOrTheRoomIsQuiet() async throws {
        _ = try await call("setNotifications", ["on": true])
        let socket = try await inRoomWithTheScreenOff()
        bridge.setVisible(true)
        socket.receive(#"{"t":"chat","msg":{"id":1,"by":"u2","name":"Ann","text":"seen","at":5}}"#)
        await settle()
        XCTAssertTrue(platform.noticesShown.isEmpty, "the screen shows it")

        bridge.setVisible(false)
        let until = Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000
        _ = try await call("muteRoomNotifications", ["code": "abc234", "until": until])
        let quiet = try await result("notifications", as: [String: Any].self)
        XCTAssertEqual((quiet["mutes"] as? [String: Any])?["ABC234"] as? Int64, until)
        socket.receive(#"{"t":"chat","msg":{"id":2,"by":"u2","name":"Ann","text":"quiet","at":6}}"#)
        await settle()
        XCTAssertTrue(platform.noticesShown.isEmpty)

        _ = try await call("muteRoomNotifications", ["code": "ABC234", "until": NSNull()])
        socket.receive(#"{"t":"chat","msg":{"id":3,"by":"u2","name":"Ann","text":"loud","at":7}}"#)
        await settle()
        XCTAssertEqual(platform.noticesShown.map(\.body), ["loud"])
    }

    func testATouchOnANoticeOpensItsChatOnTheScreen() async throws {
        bridge.onOpenChat("abc234")
        let opened = try XCTUnwrap(events.last { $0["type"] as? String == "openChat" })
        XCTAssertEqual(opened["room"] as? String, "ABC234")
    }

    func testTheRoomsChatAndReactionsReachTheScreenAndItsOwnGoOut() async throws {
        _ = try await call("configure", ["server": "https://sapoche.example.dev"])
        _ = try await call("join", ["code": "abc234", "name": "Me"])
        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        socket.open()
        socket.receive(#"{"t":"state","serverNow":1,"you":"me","protocol":10,"state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":1},"members":[]}"#)
        socket.receive(#"{"t":"chat.history","msgs":[{"id":1,"by":"u2","name":"Ann","text":"hello","at":5}]}"#)
        socket.receive(#"{"t":"chat","msg":{"id":2,"by":"me","name":"Me","text":"hi","at":6,"cid":"c-1"}}"#)
        socket.receive(#"{"t":"react","by":"u2","e":"fire","n":2}"#)
        await time.advance(10)
        let chats = events.filter { $0["type"] as? String == "chat" }
        XCTAssertEqual(chats.count, 2)
        XCTAssertEqual(chats[0]["room"] as? String, "ABC234")
        XCTAssertEqual(chats[0]["replace"] as? Bool, true)
        XCTAssertEqual((chats[0]["messages"] as? [[String: Any]])?.first?["text"] as? String, "hello")
        XCTAssertEqual(chats[1]["replace"] as? Bool, false)
        let own = try XCTUnwrap((chats[1]["messages"] as? [[String: Any]])?.first)
        XCTAssertEqual(own["cid"] as? String, "c-1")
        XCTAssertEqual(own["id"] as? Int, 2)
        let reaction = try XCTUnwrap(events.last { $0["type"] as? String == "reaction" })
        XCTAssertEqual(reaction["by"] as? String, "u2")
        XCTAssertEqual(reaction["e"] as? String, "fire")
        XCTAssertEqual(reaction["n"] as? Int, 2)

        socket.sent.removeAll()
        let sent = try await call("sendChat", ["text": "yo", "cid": "c-2"]) as? Bool
        XCTAssertEqual(sent, true)
        _ = try await call("react", ["e": "heart", "n": 3])
        let out = socket.sent.compactMap { JSON.parse($0)?.object }
        XCTAssertEqual(out.map { $0["t"] as? String }, ["chat", "react"])
        XCTAssertEqual(out[0]["text"] as? String, "yo")
        XCTAssertEqual(out[1]["n"] as? Int, 3)

        // Nothing is sent while the screen is off, and a screen that comes back gets the whole chat again, and is told
        // of the reactions that came, as ones that came late
        bridge.setVisible(false)
        events.removeAll()
        socket.receive(#"{"t":"chat","msg":{"id":3,"by":"u2","name":"Ann","text":"later","at":7}}"#)
        socket.receive(#"{"t":"react","by":"u2","e":"wow","n":1}"#)
        await time.advance(10)
        XCTAssertTrue(events.filter { ["chat", "reaction"].contains($0["type"] as? String) }.isEmpty)
        bridge.setVisible(true)
        await time.advance(10)
        let again = try XCTUnwrap(events.last { $0["type"] as? String == "chat" })
        XCTAssertEqual(again["replace"] as? Bool, true)
        XCTAssertEqual((again["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? Int }, [1, 2, 3])
        let late = events.filter { $0["type"] as? String == "reaction" }
        XCTAssertEqual(late.count, 1)
        XCTAssertEqual(late.first?["e"] as? String, "wow")
        XCTAssertEqual(late.first?["late"] as? Bool, true)
        // They are told once
        events.removeAll()
        bridge.setVisible(false)
        bridge.setVisible(true)
        XCTAssertFalse(events.contains { $0["type"] as? String == "reaction" })

        // Out of the room there is no chat to send to
        _ = try await call("leave")
        do {
            _ = try await call("sendChat", ["text": "gone", "cid": "c-3"])
            XCTFail("sent outside a room")
        } catch {}
    }

    func testRepliesReactionsToAMessageAndWhoHasGotItGoBothWays() async throws {
        _ = try await call("configure", ["server": "https://sapoche.example.dev"])
        _ = try await call("join", ["code": "abc234", "name": "Me"])
        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        socket.open()
        socket.receive(#"{"t":"state","serverNow":1,"you":"me","protocol":12,"state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":1},"members":[]}"#)
        socket.sent.removeAll()
        // The history reaches the device: the room is told so, without the screen, once for the last message
        socket.receive(#"{"t":"chat.history","msgs":[{"id":1,"by":"u2","name":"Ann","text":"hello","at":5},{"id":2,"by":"u2","name":"Ann","text":"you there","at":6,"re":{"id":1,"by":"u2","name":"Ann","text":"hello"},"rx":{"me":"fire"}}],"receipts":{"u2":{"d":2,"r":2}}}"#)
        await time.advance(10)
        var out = socket.sent.compactMap { JSON.parse($0)?.object }.filter { $0["t"] as? String != "ping" }
        XCTAssertEqual(out.map { $0["t"] as? String }, ["chat.receipt"])
        XCTAssertEqual(out[0]["delivered"] as? Int, 2)
        XCTAssertNil(out[0]["read"])
        let history = try XCTUnwrap(events.last { $0["type"] as? String == "chat" })
        let second = try XCTUnwrap((history["messages"] as? [[String: Any]])?.last)
        XCTAssertEqual((second["re"] as? [String: Any])?["text"] as? String, "hello")
        XCTAssertEqual(second["rx"] as? [String: String], ["me": "fire"])
        let told = try XCTUnwrap(history["receipts"] as? [String: [String: Any]])
        XCTAssertEqual(told["u2"]?["r"] as? Int, 2)

        // What the device wrote itself needs no word, and one that did not change needs no second one
        socket.sent.removeAll()
        socket.receive(#"{"t":"chat","msg":{"id":3,"by":"me","name":"Me","text":"yes","at":7,"cid":"c-1"}}"#)
        socket.receive(#"{"t":"chat","msg":{"id":4,"by":"u2","name":"Ann","text":"ok","at":8}}"#)
        await time.advance(10)
        out = socket.sent.compactMap { JSON.parse($0)?.object }.filter { $0["t"] as? String != "ping" }
        XCTAssertEqual(out.compactMap { $0["delivered"] as? Int }, [4])

        // A reaction changes a message; receipts arrive on their own
        events.removeAll()
        socket.receive(#"{"t":"chat.update","msg":{"id":4,"by":"u2","name":"Ann","text":"ok","at":8,"rx":{"u2":"clap"}}}"#)
        socket.receive(#"{"t":"chat.receipts","receipts":{"u2":{"d":4,"r":3}}}"#)
        await time.advance(10)
        let chats = events.filter { $0["type"] as? String == "chat" }
        XCTAssertEqual(chats.count, 2)
        XCTAssertEqual(((chats[0]["messages"] as? [[String: Any]])?.first?["rx"]) as? [String: String], ["u2": "clap"])
        XCTAssertEqual((chats[1]["messages"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((chats[1]["receipts"] as? [String: [String: Any]])?["u2"]?["r"] as? Int, 3)

        // A page of older messages is passed to the screen as it is, and not kept for a screen that comes back
        events.removeAll()
        socket.sent.removeAll()
        let asked = try await call("loadOlderChat", ["before": 2]) as? Bool
        XCTAssertEqual(asked, true)
        socket.receive(#"{"t":"chat.page","before":2,"msgs":[{"id":1,"by":"u2","name":"Ann","text":"first","at":3}],"more":true}"#)
        await time.advance(10)
        let page = try XCTUnwrap(events.last { $0["type"] as? String == "chat" })
        XCTAssertEqual(page["older"] as? Bool, true)
        XCTAssertEqual(page["more"] as? Bool, true)
        XCTAssertEqual(page["replace"] as? Bool, false)
        XCTAssertEqual((page["messages"] as? [[String: Any]])?.first?["id"] as? Int, 1)
        out = socket.sent.compactMap { JSON.parse($0)?.object }.filter { $0["t"] as? String != "ping" }
        XCTAssertEqual(out.map { $0["t"] as? String }, ["chat.before"])
        XCTAssertEqual(out[0]["id"] as? Int, 2)

        // Commands from the screen
        socket.sent.removeAll()
        _ = try await call("sendChat", ["text": "re", "cid": "c-2", "reply": 4])
        _ = try await call("reactChat", ["id": 4, "e": "fire"])
        _ = try await call("reactChat", ["id": 4])
        _ = try await call("readChat", ["upTo": 4])
        out = socket.sent.compactMap { JSON.parse($0)?.object }.filter { $0["t"] as? String != "ping" }
        XCTAssertEqual(out.map { $0["t"] as? String }, ["chat", "chat.react", "chat.react", "chat.receipt"])
        XCTAssertEqual(out[0]["reply"] as? Int, 4)
        XCTAssertEqual(out[1]["e"] as? String, "fire")
        XCTAssertTrue(out[2]["e"] is NSNull)
        XCTAssertEqual(out[3]["read"] as? Int, 4)
    }

    func testASealedRoomsChatIsReadWithTheSecretSealedOnTheWayOutAndLockedWithout() async throws {
        _ = try await call("configure", ["server": "https://sapoche.example.dev"])
        _ = try await call("join", ["code": "abc234", "name": "Me"])
        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        socket.open()
        socket.receive(#"{"t":"state","serverNow":1,"you":"me","protocol":15,"state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":1,"ownerId":"me","enc":true},"members":[]}"#)
        await time.advance(10)
        let first = try XCTUnwrap(states().last)
        XCTAssertEqual(first["encrypted"] as? Bool, true)
        XCTAssertEqual(first["encryptionKey"] as? Bool, false, "this device has no secret yet")

        // A message sealed by another member: nothing to read without the secret
        let secret = ChatCipher.newSecret()
        let quote = ChatQuote(id: 1, by: "me", name: "Me", text: "old")
        let sealed = try XCTUnwrap(ChatCipher.sealMessage(secret: secret, room: "ABC234", by: "u2", text: "sealed hello", quote: quote))
        socket.receive(#"{"t":"chat.history","msgs":[{"id":2,"by":"u2","name":"Ann","text":"","at":5,"ct":"\#(sealed.ct)","pv":"\#(sealed.pv)"}]}"#)
        await time.advance(10)
        var message = try XCTUnwrap((events.last { $0["type"] as? String == "chat" }?["messages"] as? [[String: Any]])?.first)
        XCTAssertEqual(message["locked"] as? Bool, true)
        XCTAssertEqual(message["text"] as? String, "")

        // The secret comes (from an invitation link): the chat is shown again, readable, with the quote that was inside
        let link = URL(string: "https://sapoche.example.dev/join/ABC234#k=\(ChatCipher.encodeSecret(secret))")!
        bridge.onLink(link)
        await time.advance(10)
        XCTAssertEqual(states().last?["encryptionKey"] as? Bool, true)
        message = try XCTUnwrap((events.last { $0["type"] as? String == "chat" }?["messages"] as? [[String: Any]])?.first)
        XCTAssertEqual(message["locked"] as? Bool, false)
        XCTAssertEqual(message["text"] as? String, "sealed hello")
        XCTAssertEqual((message["re"] as? [String: Any])?["text"] as? String, "old")
        let invite = try XCTUnwrap(events.last { $0["type"] as? String == "invite" })
        XCTAssertEqual(invite["code"] as? String, "ABC234")

        // What this device writes goes out sealed, with the quote inside, and the room sees only that it answers number 2
        socket.sent.removeAll()
        let sent = try await call("sendChat", ["text": "my answer", "cid": "c-9", "reply": 2,
                                               "quote": ["id": 2, "by": "u2", "name": "Ann", "text": "sealed hello"]]) as? Bool
        XCTAssertEqual(sent, true)
        let out = try XCTUnwrap(socket.sent.compactMap { JSON.parse($0)?.object }.first { $0["t"] as? String == "chat" })
        XCTAssertNil(out["text"])
        XCTAssertEqual(out["reply"] as? Int, 2)
        let ct = try XCTUnwrap(out["ct"] as? String)
        let opened = try XCTUnwrap(ChatCipher.openMessage(secret: secret, room: "ABC234",
                                                          message: ChatMessage(id: 3, by: "me", name: "Me", text: "", at: 6, ct: ct)))
        XCTAssertEqual(opened.text, "my answer")
        XCTAssertEqual(opened.re?.text, "sealed hello")
        XCTAssertNotNil(out["pv"] as? String)

        // The secret to give others is the one this device has
        let given = try await call("roomSecret") as? String
        XCTAssertEqual(given, ChatCipher.encodeSecret(secret))
    }

    func testTheOwnerTurnsEncryptionOnAndGetsASecretToGive() async throws {
        _ = try await call("configure", ["server": "https://sapoche.example.dev"])
        _ = try await call("join", ["code": "abc234", "name": "Me"])
        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        socket.open()
        socket.receive(#"{"t":"state","serverNow":1,"you":"me","protocol":15,"state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":1,"ownerId":"u2"},"members":[]}"#)
        await time.advance(10)
        socket.sent.removeAll()
        let notOwner = try await call("enableEncryption") as? Bool
        XCTAssertEqual(notOwner, false)
        XCTAssertTrue(socket.sent.allSatisfy { !$0.contains("room.encrypt") })

        socket.receive(#"{"t":"state","serverNow":2,"you":"me","protocol":15,"state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":1,"ownerId":"me"},"members":[]}"#)
        await time.advance(10)
        let before = try await call("roomSecret") as? String
        XCTAssertNil(before)
        let done = try await call("enableEncryption") as? Bool
        XCTAssertEqual(done, true)
        XCTAssertTrue(socket.sent.contains { $0.contains("room.encrypt") })
        let made = try await call("roomSecret") as? String
        let secret = try XCTUnwrap(made)
        XCTAssertNotNil(ChatCipher.decodeSecret(secret))
        XCTAssertEqual(states().last?["encryptionKey"] as? Bool, true)

        // A secret in a link that is not one is refused
        let refused = try await call("setRoomSecret", ["room": "ABC234", "secret": "nope"]) as? Bool
        XCTAssertEqual(refused, false)
        let accepted = try await call("setRoomSecret", ["room": "ABC234", "secret": secret]) as? Bool
        XCTAssertEqual(accepted, true)
    }

    func testAnInvitationLinkReachesTheScreen() async throws {
        _ = try await call("configure", ["server": "https://sapoche.example.dev"])
        bridge.onLink(URL(string: "sapoche://join/abc234")!)
        bridge.onLink(URL(string: "https://sapoche.example.dev/join/XYZ789")!)
        bridge.onLink(URL(string: "https://elsewhere.example/join/NOPE22")!)
        bridge.onLink(URL(string: "sapoche://join/bad")!)
        let codes = events.filter { $0["type"] as? String == "invite" }.compactMap { $0["code"] as? String }
        XCTAssertEqual(codes, ["ABC234", "XYZ789"])
    }

    func testASetupLinkReachesTheScreenWhoeverIsListening() async throws {
        let link = "sapoche://setup?server=https%3A%2F%2Fsapoche.example.dev&key=k3y"
        // Opened before the screen listens: it is held, and given when it does
        bridge.stop()
        bridge.onLink(URL(string: link)!)
        events.removeAll()
        bridge.start { [weak self] text in
            if let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { self?.events.append(json) }
        }
        XCTAssertEqual(events.filter { $0["type"] as? String == "setup" }.compactMap { $0["link"] as? String }, [link])
        // Opened while it listens: it is given at once
        bridge.onLink(URL(string: link)!)
        XCTAssertEqual(events.filter { $0["type"] as? String == "setup" }.count, 2)
        XCTAssertNil(prefs.string("server_key"), "nothing is kept until the person agrees")
    }

    func testUnknownCommandsAreRefusedWithAMessage() async throws {
        do {
            _ = try await call("dance")
            XCTFail("expected a refusal")
        } catch let error as BridgeError {
            XCTAssertEqual(error.code, "failed")
        }
    }

    func testTheScreenCanWriteInTheLog() async throws {
        _ = try await call("note", ["line": "frames=120 display=120Hz"])
        let lines = try await result("log", as: [String].self)
        XCTAssertTrue(lines.contains { $0.hasSuffix("ui: frames=120 display=120Hz") })
    }

    func testTheLogHoldsWhatWasDone() async throws {
        EventLog.d("test", "something happened")
        let lines = try await result("log", as: [String].self)
        XCTAssertTrue(lines.contains { $0.hasSuffix("test: something happened") })
    }
}

@MainActor
final class GroupControllerTests: XCTestCase {
    private var time: VirtualTime!
    private var engine: FakePlayer!
    private var controller: GroupController!
    private var asked: [String] = []
    private var dir: URL!

    override func setUp() async throws {
        time = VirtualTime()
        engine = FakePlayer(time: time)
        asked = []
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let more = TrackRef(videoId: "more0000001", title: "More", artist: "A", thumb: nil, durMs: 200_000)
        controller = GroupController(
            engine: engine, prefs: MemoryStore(), queueFile: QueueFile(url: dir.appendingPathComponent("queue.json")),
            config: { ServerConfig() }, time: time,
            moreLike: { [unowned self] id, _, _ in
                self.asked.append(id)
                return [more]
            }
        )
    }

    override func tearDown() async throws {
        controller.release()
        try? FileManager.default.removeItem(at: dir)
    }

    private func song(_ n: Int) -> TrackRef {
        TrackRef(videoId: "video00000\(n)", title: "Song \(n)", artist: "A", thumb: nil, durMs: 200_000)
    }

    func testWhenTheQueueRunsOutTheMusicCarriesOnWithSongsLikeTheLastOne() async {
        controller.requestAddMany([song(1)], playNext: false)
        await time.advance(100)
        engine.onEnded?()
        await time.advance(100)
        XCTAssertEqual(asked, ["video000001"])
        XCTAssertEqual(controller.local.snapshot.value.queue.map(\.videoId), ["video000001", "more0000001"])
        XCTAssertEqual(engine.loaded?.videoId, "more0000001")
    }

    func testTurningAutoplayOffLetsTheQueueEnd() async {
        controller.autoplayOn = false
        controller.requestAddMany([song(1)], playNext: false)
        await time.advance(100)
        engine.onEnded?()
        await time.advance(100)
        XCTAssertEqual(asked, [])
        XCTAssertTrue(controller.local.snapshot.value.finished)
    }

    func testTheSleepTimerAtTheEndOfTheLastSongStopsTheMusicInsteadOfCarryingOn() async {
        controller.requestAddMany([song(1)], playNext: false)
        await time.advance(100)
        controller.sleep.startAtSongEnd()
        XCTAssertTrue(engine.pauseAtSongEnd)
        // What the player does at the end of the last song: reports it, then that it paused for the timer
        engine.onEnded?()
        engine.onSongEndPause?()
        await time.advance(100)
        XCTAssertEqual(asked, [], "the timer was still set when the queue ran out, so nothing carries on")
        XCTAssertEqual(controller.sleep.state.value, .off)
        XCTAssertFalse(engine.pauseAtSongEnd)
        XCTAssertFalse(engine.playing)
    }

    func testTheSleepTimerAtTheEndOfASongPausesThisDeviceAndNothingElse() async {
        controller.requestAddMany([song(1), song(2)], playNext: false)
        await time.advance(100)
        controller.sleep.startAtSongEnd()
        engine.onSongEndPause?()
        await time.advance(100)
        XCTAssertFalse(engine.playing)
        XCTAssertEqual(controller.local.snapshot.value.index, 0, "the next song waits for the person to press play")
    }

    func testWhenTheRoomsQueueRunsOutTheDeviceAskedSendsSongsLikeTheLastOne() async throws {
        let sockets = FakeSockets()
        let more = TrackRef(videoId: "more0000001", title: "More", artist: "A", thumb: nil, durMs: 200_000)
        let room = GroupController(
            engine: FakePlayer(time: time), prefs: MemoryStore(), queueFile: QueueFile(url: dir.appendingPathComponent("r.json")),
            config: { ServerConfig(server: "https://x") }, time: time, sockets: sockets,
            moreLike: { [unowned self] id, _, _ in
                self.asked.append(id)
                try await self.time.sleep(ms: 50) // finding songs takes a while
                return [more]
            }
        )
        room.join(code: "ABC234", name: "Me", create: false)
        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        socket.open()
        socket.receive(#"{"t":"state","serverNow":1,"you":"me","protocol":9,"state":{"queue":[{"id":"q1","videoId":"video000001","title":"Song 1","artist":"A","durMs":9,"addedBy":"me"}],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":4,"autoplay":true},"members":[]}"#)
        await time.advance(10)
        socket.sent.removeAll()

        socket.receive(#"{"t":"autoplay.fill","epoch":4,"videoId":"video000001","title":"Song 1"}"#)
        await time.advance(100)
        XCTAssertEqual(asked, ["video000001"])
        let many = try XCTUnwrap(socket.sent.compactMap { JSON.parse($0)?.object }.first { $0["t"] as? String == "queue.addMany" })
        XCTAssertEqual((many["tracks"] as? [[String: Any]])?.first?["videoId"] as? String, "more0000001")

        // The room moved on while the songs were being found: they are not sent
        socket.sent.removeAll()
        socket.receive(#"{"t":"autoplay.fill","epoch":4,"videoId":"video000001","title":"Song 1"}"#)
        socket.receive(#"{"t":"state","serverNow":2,"you":"me","protocol":9,"state":{"queue":[{"id":"q1","videoId":"video000001","title":"Song 1","artist":"A","durMs":9,"addedBy":"me"}],"index":0,"phase":"preparing","startedAt":0,"positionMs":0,"epoch":5,"autoplay":true},"members":[]}"#)
        await time.advance(100)
        XCTAssertFalse(socket.sent.contains { $0.contains("queue.addMany") })
        room.release()
    }

    /// A headset button, AirPods taken out, the lock screen: they pause this device, and the room plays on.
    func testAPauseFromOutsideStopsOnlyThisDeviceWhileTheRoomPlaysOn() async throws {
        let sockets = FakeSockets()
        let player = FakePlayer(time: time)
        let room = GroupController(
            engine: player, prefs: MemoryStore(), queueFile: QueueFile(url: dir.appendingPathComponent("t.json")),
            config: { ServerConfig(server: "https://x") }, time: time, sockets: sockets
        )
        room.join(code: "ABC234", name: "Me", create: false)
        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        socket.open()
        let item = #"{"id":"q1","videoId":"video000001","title":"Song 1","artist":"A","durMs":200000,"addedBy":"me"}"#
        socket.receive(#"{"t":"state","serverNow":0,"you":"me","protocol":9,"state":{"queue":[\#(item)],"index":0,"phase":"playing","startedAt":0,"positionMs":0,"epoch":3},"members":[]}"#)
        await time.advance(3000)
        XCTAssertTrue(player.playing)
        XCTAssertFalse(room.playerInfo().heldBack)

        socket.sent.removeAll()
        room.pauseFromOutside()
        XCTAssertFalse(player.playing, "this device went quiet")
        XCTAssertFalse(socket.sent.contains { $0.contains(#""t":"pause""#) }, "and nobody else was told to")
        XCTAssertTrue(room.playerInfo().heldBack, "so the button can say play")

        // Play resumes this device alone, again without moving the room
        room.requestPlay()
        await time.advance(100)
        XCTAssertTrue(player.playing)
        XCTAssertFalse(socket.sent.contains { $0.contains(#""t":"play""#) })
        XCTAssertFalse(room.playerInfo().heldBack)

        // The buttons of the app are the room's: they pause everybody
        room.requestPause()
        XCTAssertTrue(socket.sent.contains { $0.contains(#""t":"pause""#) })
        room.release()
    }

    func testAPauseFromOutsideOutsideARoomPausesThePersonalQueue() async {
        controller.requestAddMany([song(1)], playNext: false)
        await time.advance(100)
        XCTAssertTrue(engine.playing)
        controller.pauseFromOutside()
        XCTAssertFalse(engine.playing)
        XCTAssertFalse(controller.playerInfo().heldBack, "there is no room to be held back from")
    }

    func testTheRoomsAutoplayIsAskedAboutOnlyInARoom() async throws {
        let sockets = FakeSockets()
        let room = GroupController(
            engine: FakePlayer(time: time), prefs: MemoryStore(), queueFile: QueueFile(url: dir.appendingPathComponent("s.json")),
            config: { ServerConfig(server: "https://x") }, time: time, sockets: sockets
        )
        XCTAssertFalse(room.requestRoomAutoplay(false), "outside a room there is nobody to tell")
        room.join(code: "ABC234", name: "Me", create: false)
        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        socket.open()
        XCTAssertTrue(room.requestRoomAutoplay(false))
        XCTAssertTrue(socket.sent.contains { $0.contains(#""t":"autoplay""#) && $0.contains(#""on":false"#) })
        room.release()
    }

    func testTheRoomIsNotRejoinedLongAfterTheAppWasLeft() {
        let prefs = MemoryStore()
        prefs.set("ABC234", for: "room_code")
        prefs.set(Int64(Date().timeIntervalSince1970 * 1000) - 11 * 60_000, for: "room_last_active")
        let late = GroupController(engine: FakePlayer(time: time), prefs: prefs, queueFile: QueueFile(url: dir.appendingPathComponent("a.json")),
                                   config: { ServerConfig(server: "https://x") }, time: time, sockets: FakeSockets())
        late.recoverRoom()
        XCTAssertNil(late.roomCode)
        XCTAssertNil(prefs.string("room_code"), "a room left that long ago is forgotten")
        late.release()
    }

    func testTheRoomIsRejoinedRightAfterTheAppWasEnded() {
        let prefs = MemoryStore()
        prefs.set("ABC234", for: "room_code")
        prefs.set("Me", for: "room_name")
        prefs.set(Int64(Date().timeIntervalSince1970 * 1000) - 60_000, for: "room_last_active")
        let sockets = FakeSockets()
        let soon = GroupController(engine: FakePlayer(time: time), prefs: prefs, queueFile: QueueFile(url: dir.appendingPathComponent("b.json")),
                                   config: { ServerConfig(server: "https://x") }, time: time, sockets: sockets)
        soon.recoverRoom()
        XCTAssertEqual(soon.roomCode, "ABC234")
        soon.release()
    }
}
