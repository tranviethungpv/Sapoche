import XCTest
@testable import SapocheCore

/// The same cases as `LocalMusicTest.kt` and the local-files tests of `LibraryStoreTest.kt`: the two sides must agree.
final class LocalMusicPlanTests: XCTestCase {
    private func file(_ key: String, title: String = "Song", artist: String = "Artist", durMs: Int64 = 200_000) -> LocalFile {
        LocalFile(key: key, uri: "media/\(key)", title: title, artist: artist, album: "Album", durMs: durMs, mime: "audio/mpeg", size: 4_000_000, addedAt: 1)
    }

    private func known(_ id: String, _ key: String, title: String = "Song", artist: String = "Artist", durMs: Int64 = 200_000, referenced: Bool = true) -> KnownLocal {
        KnownLocal(id: id, key: key, title: title, artist: artist, durMs: durMs, referenced: referenced)
    }

    func testAnIdNeverLooksLikeTheIdOfAYouTubeVideo() {
        let id = LocalMusic.id("Music/a.mp3")
        XCTAssertTrue(LocalMusic.isLocal(id))
        XCTAssertEqual(id.count, 6 + 16)
        XCTAssertNil(id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression))
        XCTAssertFalse(LocalMusic.isLocal("dQw4w9WgXcQ"))
    }

    func testAnIdIsTheSameForTheSameKeyAndDiffersBetweenKeysAndAttempts() {
        XCTAssertEqual(LocalMusic.id("Music/a.mp3"), LocalMusic.id("Music/a.mp3"))
        XCTAssertNotEqual(LocalMusic.id("Music/a.mp3"), LocalMusic.id("Music/b.mp3"))
        XCTAssertNotEqual(LocalMusic.id("Music/a.mp3"), LocalMusic.id("Music/a.mp3", attempt: 1))
        // The values of the Kotlin side, so that both make the same ids
        XCTAssertEqual(LocalMusic.id("a"), "local:af63dc4c8601ec8c")
        XCTAssertEqual(LocalMusic.id(""), "local:cbf29ce484222325")
        XCTAssertEqual(LocalMusic.id("Music/a.mp3"), "local:720a06ef3759f374")
        XCTAssertEqual(LocalMusic.id("é"), "local:0ac21707b7181e01")
    }

    func testAFileSeenBeforeKeepsItsId() {
        let plan = LocalMusic.plan(found: [file("k1", title: "Renamed")], known: [known("local:1", "k1")])
        XCTAssertEqual(plan.files.map(\.id), ["local:1"])
        XCTAssertTrue(plan.missing.isEmpty && plan.forget.isEmpty)
    }

    func testANewFileGetsTheIdOfItsKey() {
        XCTAssertEqual(LocalMusic.plan(found: [file("k1")], known: []).files.map(\.id), [LocalMusic.id("k1")])
    }

    func testAFileThatIsGoneIsKeptAsMissingWhenPointedToAndForgottenOtherwise() {
        let plan = LocalMusic.plan(found: [], known: [known("local:1", "k1", referenced: true), known("local:2", "k2", referenced: false)])
        XCTAssertEqual(plan.missing, ["local:1"])
        XCTAssertEqual(plan.forget, ["local:2"])
    }

    func testAFileThatMovedTakesItsSongOver() {
        let plan = LocalMusic.plan(found: [file("new/place.mp3", durMs: 201_000)], known: [known("local:1", "old/place.mp3")])
        XCTAssertEqual(plan.files.map(\.id), ["local:1"])
        XCTAssertEqual(plan.files.first?.file.key, "new/place.mp3")
        XCTAssertTrue(plan.missing.isEmpty && plan.forget.isEmpty)
    }

    func testAMovedFileIsToldByTitleAndArtistWhateverTheCaseAndSpacing() {
        let plan = LocalMusic.plan(found: [file("n", title: "  my   SONG ", artist: "the artist")],
                                   known: [known("local:1", "o", title: "My Song", artist: "The Artist")])
        XCTAssertEqual(plan.files.map(\.id), ["local:1"])
    }

    func testAFileOfAnotherLengthIsAnotherSong() {
        let plan = LocalMusic.plan(found: [file("n", durMs: 230_000)], known: [known("local:1", "o", durMs: 200_000)])
        XCTAssertEqual(plan.files.map(\.id), [LocalMusic.id("n")])
        XCTAssertEqual(plan.missing, ["local:1"])
    }

    func testNothingIsJoinedWhenTwoMissingFilesLookLikeTheNewOne() {
        let plan = LocalMusic.plan(found: [file("n")], known: [known("local:1", "o1"), known("local:2", "o2")])
        XCTAssertEqual(plan.files.map(\.id), [LocalMusic.id("n")])
        XCTAssertEqual(plan.missing, ["local:1", "local:2"])
    }

    func testNothingIsJoinedWhenTwoNewFilesLookLikeTheMissingOne() {
        let plan = LocalMusic.plan(found: [file("n1"), file("n2")], known: [known("local:1", "o")])
        XCTAssertEqual(plan.files.map(\.id), [LocalMusic.id("n1"), LocalMusic.id("n2")])
        XCTAssertEqual(plan.missing, ["local:1"])
    }

    func testANewFileWhoseIdIsTakenGetsAnotherId() {
        let taken = LocalMusic.id("k")
        let plan = LocalMusic.plan(found: [file("k"), file("other", title: "Else")], known: [known(taken, "moved-away", title: "Else 2")])
        let id = plan.files.first { $0.file.key == "k" }?.id
        XCTAssertNotEqual(id, taken)
        XCTAssertTrue(LocalMusic.isLocal(id ?? ""))
    }

    func testTheCoverAddressNamesTheSong() {
        XCTAssertEqual(LocalMusic.cover("local:1"), "sapoche-local:local:1")
    }
}

final class LocalLibraryTests: XCTestCase {
    private var store: LibraryStore!

    override func setUpWithError() throws {
        store = try LibraryStore(path: ":memory:")
    }

    private func file(_ key: String, title: String? = nil, durMs: Int64 = 200_000, addedAt: Int64 = 1) -> LocalFile {
        LocalFile(key: key, uri: "media/\(key)", title: title ?? "Local \(key)", artist: "Mine", album: "Album", durMs: durMs, mime: "audio/mpeg", size: 1_000, addedAt: addedAt)
    }

    private func song(_ id: String) -> TrackRef {
        TrackRef(videoId: id, title: "Title \(id)", artist: "Artist", thumb: nil, durMs: 200_000)
    }

    func testAScanListsTheFilesAsSongsWithTheirCoverMarker() async throws {
        let total = try await store.applyLocalScan([file("a", addedAt: 10), file("b", addedAt: 20)])
        XCTAssertEqual(total, 2)
        let listed = try await store.localSongs()
        XCTAssertEqual(listed.map(\.track.videoId), [LocalMusic.id("b"), LocalMusic.id("a")])
        XCTAssertEqual(listed.first?.track.thumb, LocalMusic.cover(LocalMusic.id("b")))
        let uri = try await store.localUri(LocalMusic.id("b"))
        XCTAssertEqual(uri, "media/b")
        let summary = try await store.localSummary()
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.missing, [])
    }

    func testASecondScanOfTheSameFilesChangesNothingAndSaysNothing() async throws {
        let changes = Counter()
        store = try LibraryStore(path: ":memory:", onChange: { changes.bump() })
        _ = try await store.applyLocalScan([file("a")])
        let before = changes.count
        _ = try await store.applyLocalScan([file("a")])
        XCTAssertEqual(changes.count, before)
        _ = try await store.applyLocalScan([file("a", title: "Renamed")])
        XCTAssertEqual(changes.count, before + 1)
        let songs = try await store.localSongs()
        XCTAssertEqual(songs.first?.track.title, "Renamed")
    }

    func testAFileThatIsGoneIsForgottenUnlessSomethingPointsToItsSong() async throws {
        _ = try await store.applyLocalScan([file("a"), file("b")])
        let a = try await store.localSongs().first { $0.track.title == "Local a" }!
        try await store.setLiked(a.track, true, at: 5)
        let total = try await store.applyLocalScan([])
        XCTAssertEqual(total, 0)
        let kept = try await store.localSongs()
        XCTAssertEqual(kept.map(\.track.videoId), [LocalMusic.id("a")])
        XCTAssertTrue(kept.first?.missing == true)
        let uri = try await store.localUri(LocalMusic.id("a"))
        XCTAssertNil(uri)
        let summary = try await store.localSummary()
        XCTAssertEqual(summary.count, 0)
        XCTAssertEqual(summary.missing, [LocalMusic.id("a")])
        let liked = try await store.liked()
        XCTAssertEqual(liked.map(\.track.videoId), [LocalMusic.id("a")])
    }

    func testAFileThatMovedKeepsItsLikesAndItsPlaylists() async throws {
        _ = try await store.applyLocalScan([file("old/place.mp3", title: "Same song")])
        let track = try await store.localSongs().first!.track
        try await store.setLiked(track, true, at: 5)
        let playlist = try await store.createPlaylist("Mine", [track])
        _ = try await store.applyLocalScan([file("new/place.mp3", title: "Same song", durMs: 201_000)])
        let moved = try await store.localSongs()
        XCTAssertEqual(moved.map(\.track.videoId), [track.videoId])
        XCTAssertFalse(moved[0].missing)
        let uri = try await store.localUri(track.videoId)
        XCTAssertEqual(uri, "media/new/place.mp3")
        let liked = try await store.liked()
        XCTAssertEqual(liked.map(\.track.videoId), [track.videoId])
        let inPlaylist = try await store.playlistTracks(playlist)
        XCTAssertEqual(inPlaylist.map(\.videoId), [track.videoId])
    }

    func testAFileThatComesBackIsNotMissingAnyMore() async throws {
        _ = try await store.applyLocalScan([file("a")])
        let first = try await store.localSongs()[0].track
        try await store.setLiked(first, true, at: 5)
        _ = try await store.applyLocalScan([])
        let gone = try await store.localSongs()
        XCTAssertTrue(gone[0].missing)
        _ = try await store.applyLocalScan([file("a")])
        let back = try await store.localSongs()
        XCTAssertFalse(back[0].missing)
    }

    func testSongsFromFilesAreLeftOutOfABackupAndCounted() async throws {
        _ = try await store.applyLocalScan([file("a")])
        let local = try await store.localSongs()[0].track
        try await store.setLiked(local, true, at: 1)
        try await store.recordListen(local, at: 2)
        _ = try await store.createPlaylist("Mixed", [local, song("yt")])
        try await store.setLiked(song("yt"), true, at: 3)
        let backup = try await store.backup()
        XCTAssertEqual(backup.liked.map(\.track.videoId), ["yt"])
        XCTAssertEqual(backup.listens.map(\.track.videoId), [])
        XCTAssertEqual(backup.playlists.first?.tracks.map(\.videoId), ["yt"])
        XCTAssertEqual(backup.skippedLocal, 1)
    }

    func testSongsFromFilesAreNeverOfferedForAutomaticDownload() async throws {
        _ = try await store.applyLocalScan([file("a")])
        let first = try await store.localSongs()[0].track
        try await store.setLiked(first, true, at: 1)
        try await store.setLiked(song("yt"), true, at: 2)
        let wanted = try await store.likedToDownload()
        XCTAssertEqual(wanted.map(\.videoId), ["yt"])
    }

    func testASongFromAFileIsNeverASeedNorADailyPick() {
        let local = TrackRef(videoId: "local:0123456789abcdef", title: "T", artist: "Mine", thumb: nil, durMs: 200_000)
        let other = TrackRef(videoId: "b", title: "T", artist: "Other", thumb: nil, durMs: 200_000)
        let day: Int64 = 24 * 60 * 60 * 1000
        let now: Int64 = 1_000 * day
        let taste = Taste(heard: [Stamped(track: local, at: now - day), Stamped(track: other, at: now - 2 * day)], liked: [], skipped: [], now: now)
        XCTAssertEqual(taste.seeds(5), ["b"])
        XCTAssertTrue(taste.knows("Mine"))
        let plays = (1...6).map { Stamped(track: local, at: now - Int64($0) * day) }
        XCTAssertTrue(Taste(heard: plays, liked: [], skipped: [], now: now, hourOf: { _ in 12 }).contextSeeds("afternoon").isEmpty)
    }
}

final class MusicFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("music-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func make(_ path: String, bytes: Int = 10) throws -> URL {
        let url = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private func folder(_ tags: [String: MusicTags]) -> MusicFolder {
        MusicFolder(root: root, readTags: { tags[$0.lastPathComponent] }, now: { 42 })
    }

    func testItListsTheMusicInTheFolderAndInTheFoldersInsideIt() async throws {
        try make("a.mp3")
        try make("Albums/Blue/b.m4a", bytes: 20)
        let scan = await folder([
            "a.mp3": MusicTags(title: "Alpha", artist: "Ann", album: "One", durMs: 60_000),
            "b.m4a": MusicTags(title: "Beta", artist: nil, album: nil, durMs: 90_000),
        ]).scan()
        XCTAssertEqual(scan.files.map(\.key), ["Albums/Blue/b.m4a", "a.mp3"])
        let alpha = try XCTUnwrap(scan.files.first { $0.key == "a.mp3" })
        XCTAssertEqual([alpha.title, alpha.artist, alpha.album, alpha.mime], ["Alpha", "Ann", "One", "audio/mpeg"])
        XCTAssertEqual(alpha.uri, "a.mp3")
        XCTAssertEqual(alpha.size, 10)
        XCTAssertEqual(alpha.durMs, 60_000)
        let beta = try XCTUnwrap(scan.files.first { $0.key == "Albums/Blue/b.m4a" })
        XCTAssertEqual(beta.artist, "")
        XCTAssertEqual(beta.album, "")
        XCTAssertEqual(beta.title, "Beta")
    }

    func testAFileWithNoTitleIsNamedByItsFile() async throws {
        try make("My song.flac")
        let scan = await folder(["My song.flac": MusicTags(title: "  ", artist: nil, album: nil, durMs: 45_000)]).scan()
        XCTAssertEqual(scan.files.first?.title, "My song")
    }

    func testWhatIsNotAFullSongOrNotMusicIsLeftOut() async throws {
        try make("voice.m4a")
        try make("notes.txt")
        try make("cover.jpg")
        try make("unreadable.mp3")
        try make("ok.wav")
        let scan = await folder([
            "voice.m4a": MusicTags(title: "Voice", artist: nil, album: nil, durMs: 10_000),
            "ok.wav": MusicTags(title: "Ok", artist: nil, album: nil, durMs: 30_000),
        ]).scan()
        XCTAssertEqual(scan.files.map(\.key), ["ok.wav"])
        XCTAssertEqual(scan.unsupported, 0)
    }

    func testMusicThatAnIPhoneCannotPlayIsCountedNotListed() async throws {
        try make("a.ogg")
        try make("b.OPUS")
        try make("c.mp3")
        let scan = await folder(["c.mp3": MusicTags(title: "C", artist: nil, album: nil, durMs: 60_000)]).scan()
        XCTAssertEqual(scan.files.map(\.key), ["c.mp3"])
        XCTAssertEqual(scan.unsupported, 2)
    }

    func testHiddenFilesAreSkipped() async throws {
        try make(".hidden.mp3")
        let scan = await folder([".hidden.mp3": MusicTags(title: "H", artist: nil, album: nil, durMs: 60_000)]).scan()
        XCTAssertTrue(scan.files.isEmpty)
    }

    func testTwoScansOfOneFolderGiveTheSameList() async throws {
        for n in 1...5 { try make("s\(n).mp3") }
        var tags: [String: MusicTags] = [:]
        for n in 1...5 { tags["s\(n).mp3"] = MusicTags(title: "S\(n)", artist: nil, album: nil, durMs: 60_000) }
        let a = await folder(tags).scan().files
        let b = await folder(tags).scan().files
        XCTAssertEqual(a, b)
    }

    func testTheFolderGetsAFileThatSaysWhatItIsFor() throws {
        let music = folder([:])
        music.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(MusicFolder.helpName).path))
        // It does not overwrite what the person did with it
        try "mine".write(to: root.appendingPathComponent(MusicFolder.helpName), atomically: true, encoding: .utf8)
        music.prepare()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(MusicFolder.helpName), encoding: .utf8), "mine")
    }

    func testTheHelpFileIsNotMusic() async throws {
        let music = folder([:])
        music.prepare()
        let scan = await music.scan()
        XCTAssertTrue(scan.files.isEmpty)
    }

    func testAKeyIsFoundAgainInsideTheFolder() throws {
        let url = try make("Albums/Blue/b.m4a")
        XCTAssertEqual(folder([:]).url(forKey: "Albums/Blue/b.m4a").path, url.path)
    }

    func testFilesPickedAreCopiedInAndANameAlreadyTakenGetsANumber() throws {
        let picked = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: picked) }
        let one = picked.appendingPathComponent("song.mp3")
        try Data([1]).write(to: one)
        try make("song.mp3")
        let music = folder([:])
        XCTAssertEqual(music.copyIn([one, picked.appendingPathComponent("missing.mp3")]), 1, "one that cannot be copied is skipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("song (2).mp3").path))
        XCTAssertEqual(music.copyIn([one]), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("song (3).mp3").path))
    }
}

final class LocalPlaybackTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-play-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let resolver = FakeResolver()

    private func library(_ location: @escaping @Sendable (String) async -> URL?) -> MediaLibrary {
        let files = MediaFiles(downloadsDir: dir.appendingPathComponent("d"), playDir: dir.appendingPathComponent("p"), playLimitBytes: 1 << 20)
        return MediaLibrary(files: files, streams: StreamCache(resolver: resolver), fetcher: FakeFetcher(), localFile: location)
    }

    func testASongFromAFileIsPlayedFromWhereItIs() async throws {
        let file = dir.appendingPathComponent("song.mp3")
        try Data([1, 2, 3]).write(to: file)
        let media = library { _ in file }
        let atOnce = try await media.playableAtOnce("local:0123456789abcdef")
        XCTAssertEqual(atOnce, Playable(url: file, isFile: true, headers: [:]))
        let whole = try await media.playable("local:0123456789abcdef", piecesWhenLong: false)
        XCTAssertEqual(whole.url, file)
    }

    func testAFileThatIsGoneFailsLikeASongYouTubeWillNotPlay() async throws {
        let media = library { _ in self.dir.appendingPathComponent("gone.mp3") }
        do {
            _ = try await media.playableAtOnce("local:0123456789abcdef")
            XCTFail("should not play")
        } catch let failure as LoadFailure {
            XCTAssertEqual(failure.reason, .unplayable)
        }
        let unknown = library { _ in nil }
        do {
            _ = try await unknown.playable("local:0123456789abcdef")
            XCTFail("should not play")
        } catch let failure as LoadFailure {
            XCTAssertEqual(failure.reason, .unplayable)
        }
    }

    func testAFileThePlayerWillNotOpenHasNoStreamToFallBackOn() async throws {
        let media = library { _ in nil }
        do {
            _ = try await media.streamed("local:0123456789abcdef")
            XCTFail("a song from a file has no stream")
        } catch let failure as LoadFailure {
            XCTAssertEqual(failure.reason, .unplayable)
        }
        // And forgetting or refreshing it touches nothing
        await media.forget("local:0123456789abcdef")
        await media.refresh("local:0123456789abcdef")
        let video = try await media.video("local:0123456789abcdef", maxHeight: 720)
        XCTAssertNil(video)
        let pictured = try await media.pictured("local:0123456789abcdef", maxHeight: 720)
        XCTAssertNil(pictured)
        XCTAssertEqual(resolver.asked, [], "a song from a file is never looked up on YouTube")
    }
}
