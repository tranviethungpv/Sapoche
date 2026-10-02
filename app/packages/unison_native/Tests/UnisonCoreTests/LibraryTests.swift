import XCTest
@testable import UnisonCore

/// Each test gets an empty database that lives in memory.
final class LibraryStoreTests: XCTestCase {
    private var store: LibraryStore!

    private func song(_ id: String, durMs: Int64 = 200_000) -> TrackRef {
        TrackRef(videoId: id, title: "Title \(id)", artist: "Artist", thumb: "https://img/\(id)", durMs: durMs)
    }

    override func setUpWithError() throws {
        store = try LibraryStore(path: ":memory:")
    }

    private func ids(_ id: Int64) async throws -> [String] {
        try await store.playlistTracks(id).map(\.videoId)
    }

    func testLikedSongsComeBackNewestFirst() async throws {
        try await store.setLiked(song("a"), true, at: 100)
        try await store.setLiked(song("b"), true, at: 300)
        try await store.setLiked(song("c"), true, at: 200)
        let liked = try await store.liked()
        XCTAssertEqual(liked.map(\.track.videoId), ["b", "c", "a"])
        XCTAssertEqual(liked[0].track, song("b"))
    }

    func testLikingTwiceKeepsTheFirstTime() async throws {
        try await store.setLiked(song("a"), true, at: 100)
        try await store.setLiked(song("a"), true, at: 500)
        let liked = try await store.liked()
        XCTAssertEqual(liked.map(\.at), [100])
    }

    func testUnlikingRemovesTheSong() async throws {
        try await store.setLiked(song("a"), true, at: 1)
        try await store.setLiked(song("b"), true, at: 2)
        try await store.setLiked(song("a"), false)
        let liked = try await store.liked()
        XCTAssertEqual(liked.map(\.track.videoId), ["b"])
    }

    func testALikedSongKeepsItsDetailsWhenHeard() async throws {
        try await store.setLiked(song("a"), true, at: 1)
        var renamed = song("a")
        renamed.title = "New title"
        try await store.recordListen(renamed, at: 2)
        let liked = try await store.liked()
        XCTAssertEqual(liked.first?.track.title, "New title")
    }

    func testAnUnknownLengthDoesNotEraseAKnownOne() async throws {
        try await store.setLiked(song("a", durMs: 180_000), true, at: 1)
        try await store.recordListen(song("a", durMs: 0), at: 2)
        let liked = try await store.liked()
        XCTAssertEqual(liked.first?.track.durMs, 180_000)
    }

    func testRecentListsEachSongOnceWithTheLastTimeAndCount() async throws {
        try await store.recordListen(song("a"), at: 10)
        try await store.recordListen(song("b"), at: 20)
        try await store.recordListen(song("a"), at: 30)
        let recent = try await store.recent()
        XCTAssertEqual(recent.map(\.track.videoId), ["a", "b"])
        XCTAssertEqual(recent.map(\.at), [30, 20])
        XCTAssertEqual(recent.map(\.plays), [2, 1])
    }

    func testRecentHonoursTheLimit() async throws {
        for i in 1...5 { try await store.recordListen(song("s\(i)"), at: Int64(i)) }
        let recent = try await store.recent(limit: 2)
        XCTAssertEqual(recent.map(\.track.videoId), ["s5", "s4"])
    }

    func testOnlyTheLastListensAreKept() async throws {
        for i in 1...(LibraryStore.historyKeep + 5) { try await store.recordListen(song("s"), at: Int64(i)) }
        let recent = try await store.recent()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].plays, LibraryStore.historyKeep)
        XCTAssertEqual(recent[0].at, Int64(LibraryStore.historyKeep + 5))
    }

    func testClearingTheHistoryKeepsLikesAndForgetsTheRest() async throws {
        try await store.setLiked(song("a"), true, at: 1)
        try await store.recordListen(song("a"), at: 2)
        try await store.recordListen(song("b"), at: 3)
        try await store.clearHistory()
        let recent = try await store.recent()
        XCTAssertEqual(recent.map(\.track.videoId), [])
        let liked = try await store.liked()
        XCTAssertEqual(liked.map(\.track.videoId), ["a"])
        // The song that was only in the history is gone, and can come back
        try await store.recordListen(song("b"), at: 4)
        let again = try await store.recent()
        XCTAssertEqual(again.map(\.track.videoId), ["b"])
    }

    func testASongUnlikedButStillInTheHistoryIsKept() async throws {
        try await store.setLiked(song("a"), true, at: 1)
        try await store.recordListen(song("a"), at: 2)
        try await store.setLiked(song("a"), false)
        let recent = try await store.recent()
        XCTAssertEqual(recent.first?.track.title, "Title a")
    }

    func testEveryWriteIsAnnounced() async throws {
        let counter = Counter()
        let counted = try LibraryStore(path: ":memory:", onChange: { counter.bump() })
        try await counted.setLiked(song("a"), true)
        try await counted.recordListen(song("a"))
        try await counted.clearHistory()
        XCTAssertEqual(counter.count, 3)
    }

    // ------------------------------------------------------------------ playlists

    func testAPlaylistKeepsItsSongsInTheOrderGiven() async throws {
        let id = try await store.createPlaylist("Road trip", [song("c"), song("a"), song("b")])
        let order = try await ids(id)
        XCTAssertEqual(order, ["c", "a", "b"])
        let tracks = try await store.playlistTracks(id)
        XCTAssertEqual(tracks[1], song("a"))
    }

    func testTheListShowsNameCountAndTheFirstCover() async throws {
        let id = try await store.createPlaylist("Road trip", [song("c"), song("a")], at: 10)
        _ = try await store.createPlaylist("Empty", [], at: 20)
        let lists = try await store.playlists()
        XCTAssertEqual(lists.map(\.name), ["Empty", "Road trip"], "the one changed last first")
        let trip = try XCTUnwrap(lists.first { $0.id == id })
        XCTAssertEqual(trip.count, 2)
        XCTAssertEqual(trip.thumb, "https://img/c")
        XCTAssertEqual(lists[0].count, 0)
        XCTAssertNil(lists[0].thumb)
    }

    func testAddingKeepsWhatIsThereAndSkipsRepeats() async throws {
        let id = try await store.createPlaylist("Mix", [song("a"), song("b")])
        let added = try await store.addToPlaylist(id, [song("b"), song("c"), song("d")])
        XCTAssertEqual(added, 2)
        let order = try await ids(id)
        XCTAssertEqual(order, ["a", "b", "c", "d"])
    }

    func testRemovingASongClosesTheGap() async throws {
        let id = try await store.createPlaylist("Mix", [song("a"), song("b"), song("c")])
        try await store.removeFromPlaylist(id, "b")
        let first = try await ids(id)
        XCTAssertEqual(first, ["a", "c"])
        _ = try await store.addToPlaylist(id, [song("d")])
        let second = try await ids(id)
        XCTAssertEqual(second, ["a", "c", "d"])
    }

    func testASongCanBeMovedUpAndDown() async throws {
        let id = try await store.createPlaylist("Mix", [song("a"), song("b"), song("c"), song("d")])
        try await store.movePlaylistItem(id, "d", toIndex: 0)
        var order = try await ids(id)
        XCTAssertEqual(order, ["d", "a", "b", "c"])
        try await store.movePlaylistItem(id, "d", toIndex: 2)
        order = try await ids(id)
        XCTAssertEqual(order, ["a", "b", "d", "c"])
        try await store.movePlaylistItem(id, "a", toIndex: 99)
        order = try await ids(id)
        XCTAssertEqual(order, ["b", "d", "c", "a"], "past the end means last")
        try await store.movePlaylistItem(id, "zzz", toIndex: 0)
        order = try await ids(id)
        XCTAssertEqual(order, ["b", "d", "c", "a"], "a song that is not there changes nothing")
    }

    func testRenamingTrimsAndNeverLeavesAnEmptyName() async throws {
        let id = try await store.createPlaylist("  Old  ")
        var lists = try await store.playlists()
        XCTAssertEqual(lists[0].name, "Old")
        try await store.renamePlaylist(id, "  New name ")
        lists = try await store.playlists()
        XCTAssertEqual(lists[0].name, "New name")
        try await store.renamePlaylist(id, "   ")
        lists = try await store.playlists()
        XCTAssertEqual(lists[0].name, "Untitled")
        try await store.renamePlaylist(id, String(repeating: "x", count: 200))
        lists = try await store.playlists()
        XCTAssertEqual(lists[0].name.count, LibraryStore.maxName)
    }

    func testDeletingAPlaylistKeepsSongsUsedElsewhereAndForgetsTheRest() async throws {
        try await store.setLiked(song("a"), true, at: 1)
        let id = try await store.createPlaylist("Mix", [song("a"), song("b")])
        try await store.deletePlaylist(id)
        let lists = try await store.playlists()
        XCTAssertEqual(lists.map(\.name), [])
        let gone = try await ids(id)
        XCTAssertEqual(gone, [])
        let liked = try await store.liked()
        XCTAssertEqual(liked.first?.track.title, "Title a")
        // b was only in the playlist, so it is gone and can be added again
        let again = try await store.createPlaylist("Again", [song("b")])
        let order = try await ids(again)
        XCTAssertEqual(order, ["b"])
    }

    func testASongInAPlaylistSurvivesClearingHistoryAndUnliking() async throws {
        let id = try await store.createPlaylist("Mix", [song("a")])
        try await store.recordListen(song("a"), at: 1)
        try await store.setLiked(song("a"), true, at: 2)
        try await store.clearHistory()
        try await store.setLiked(song("a"), false)
        let tracks = try await store.playlistTracks(id)
        XCTAssertEqual(tracks.first?.title, "Title a")
    }

    func testAPlaylistHoldsAtMostFiveHundredSongs() async throws {
        let id = try await store.createPlaylist("Big", (1...(LibraryStore.maxPlaylist + 20)).map { song("s\($0)") })
        let tracks = try await store.playlistTracks(id)
        XCTAssertEqual(tracks.count, LibraryStore.maxPlaylist)
        let none = try await store.addToPlaylist(id, [song("more")])
        XCTAssertEqual(none, 0)
        // Room comes back when a song is taken out
        try await store.removeFromPlaylist(id, "s1")
        let one = try await store.addToPlaylist(id, [song("more")])
        XCTAssertEqual(one, 1)
        let order = try await ids(id)
        XCTAssertEqual(order.last, "more")
    }

    func testChangingAPlaylistBringsItToTheTop() async throws {
        let first = try await store.createPlaylist("First", [], at: 10)
        _ = try await store.createPlaylist("Second", [], at: 20)
        _ = try await store.addToPlaylist(first, [song("a")], at: 30)
        let lists = try await store.playlists()
        XCTAssertEqual(lists.map(\.name), ["First", "Second"])
    }

    // ------------------------------------------------------------------ suggestions

    func testEveryListenComesBackWithItsOwnTime() async throws {
        try await store.recordListen(song("a"), at: 10)
        try await store.recordListen(song("b"), at: 30)
        try await store.recordListen(song("a"), at: 20)
        let listens = try await store.listens()
        XCTAssertEqual(listens.map(\.track.videoId), ["b", "a", "a"])
        XCTAssertEqual(listens.map(\.at), [30, 20, 10])
    }

    func testSongsLeftAfterAFewSecondsAreKeptAndForgottenWithTheHistory() async throws {
        try await store.recordSkip(song("a"), at: 1)
        try await store.recordSkip(song("b"), at: 2)
        let skipped = try await store.skipped()
        XCTAssertEqual(skipped.map(\.track.videoId), ["b", "a"])
        // A skipped song is a song something points to, so its details are kept
        XCTAssertEqual(skipped.first?.track.title, "Title b")
        try await store.clearHistory()
        let after = try await store.skipped()
        XCTAssertEqual(after.count, 0)
    }

    func testOnlyTheLastSkipsAreKept() async throws {
        for i in 0..<(LibraryStore.skipsKeep + 20) { try await store.recordSkip(song("s"), at: Int64(i)) }
        let skipped = try await store.skipped()
        XCTAssertEqual(skipped.count, LibraryStore.skipsKeep)
        XCTAssertEqual(skipped.first?.at, Int64(LibraryStore.skipsKeep + 19))
    }

    func testBlockedSongsAndArtistsAreListedAndCanBeLetBack() async throws {
        try await store.block(kind: "song", key: "x", label: "Song X", at: 1)
        try await store.block(kind: "artist", key: "some artist", label: "Some Artist", at: 2)
        try await store.block(kind: "song", key: "x", label: "Song X renamed", at: 3)
        let blocked = try await store.blocked()
        XCTAssertEqual(blocked, [LibraryStore.Blocked(kind: "song", key: "x", label: "Song X renamed"),
                                 LibraryStore.Blocked(kind: "artist", key: "some artist", label: "Some Artist")])
        try await store.unblock(kind: "song", key: "x")
        let left = try await store.blocked()
        XCTAssertEqual(left.map(\.kind), ["artist"])
    }

    func testWhatWasFetchedForASeedComesBackWithItsTime() async throws {
        let none = try await store.cachedSuggestions("seed")
        XCTAssertNil(none)
        var quoted = song("b")
        quoted.thumb = nil
        quoted.title = "Quote \" and, comma"
        try await store.putSuggestions("seed", [song("a"), quoted], at: 42)
        let found = try await store.cachedSuggestions("seed")
        let kept = try XCTUnwrap(found)
        XCTAssertEqual(kept.fetchedAt, 42)
        XCTAssertEqual(kept.tracks.map(\.videoId), ["a", "b"])
        XCTAssertEqual(kept.tracks[0], song("a"))
        XCTAssertEqual(kept.tracks[1], quoted)
    }

    func testFetchingAgainReplacesTheOldList() async throws {
        try await store.putSuggestions("seed", [song("a")], at: 1)
        try await store.putSuggestions("seed", [song("b")], at: 2)
        let kept = try await store.cachedSuggestions("seed")
        XCTAssertEqual(kept?.tracks.map(\.videoId), ["b"])
    }

    func testSuggestionsOfSeedsThatAreGoneAreForgotten() async throws {
        try await store.putSuggestions("a", [song("x")], at: 1)
        try await store.putSuggestions("b", [song("y")], at: 1)
        try await store.keepSuggestionsFor(["b"])
        let gone = try await store.cachedSuggestions("a")
        XCTAssertNil(gone)
        let kept = try await store.cachedSuggestions("b")
        XCTAssertEqual(kept?.tracks.count, 1)
        try await store.keepSuggestionsFor([])
        let none = try await store.cachedSuggestions("b")
        XCTAssertNil(none)
    }

    func testHeardAndLikedSongsCanBeListed() async throws {
        try await store.recordListen(song("old"), at: 10)
        try await store.recordListen(song("new"), at: 100)
        try await store.setLiked(song("liked"), true, at: 5)
        let late = try await store.heardSince(50)
        XCTAssertEqual(late, ["new"])
        let all = try await store.heardSince(0)
        XCTAssertEqual(all, ["old", "new"])
        let liked = try await store.likedIds()
        XCTAssertEqual(liked, ["liked"])
    }

    func testSuggestionsDoNotKeepASongAliveInTheLibrary() async throws {
        try await store.recordListen(song("a"), at: 1)
        try await store.putSuggestions("a", [song("x")], at: 1)
        try await store.clearHistory()
        // The suggestion list is its own thing: it stays, and the heard song is gone
        let recent = try await store.recent()
        XCTAssertEqual(recent.map(\.track.videoId), [])
        let kept = try await store.cachedSuggestions("a")
        XCTAssertEqual(kept?.tracks.count, 1)
    }

    // ------------------------------------------------------------------ downloads

    private func states() async throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try await store.downloads().map { ($0.track.videoId, $0.state) })
    }

    func testRequestedSongsAreQueuedInOrderAndDoneOnesComeFirst() async throws {
        try await store.requestDownloads([song("a"), song("b"), song("c")], at: 1)
        let first = try await store.nextDownload(LibraryStore.queued)
        XCTAssertEqual(first, "a")
        try await store.finishDownload("b", bytes: 1234, at: 10)
        try await store.finishDownload("a", bytes: 99, at: 20)
        let list = try await store.downloads()
        XCTAssertEqual(list.map(\.track.videoId), ["a", "b", "c"], "done ones newest first, then the waiting")
        XCTAssertEqual(list.map(\.state), [LibraryStore.done, LibraryStore.done, LibraryStore.queued])
        XCTAssertEqual(list[0].bytes, 99)
        let next = try await store.nextDownload(LibraryStore.queued)
        XCTAssertEqual(next, "c")
        let waiting = try await store.nextDownload(LibraryStore.waiting)
        XCTAssertNil(waiting)
    }

    func testASongAlreadyDoneStaysDoneWhenAskedAgain() async throws {
        try await store.requestDownloads([song("a")])
        try await store.finishDownload("a", bytes: 10)
        try await store.requestDownloads([song("a")])
        let all = try await states()
        XCTAssertEqual(all, ["a": LibraryStore.done])
    }

    func testAskingForAWaitingSongThePlainWayStartsItNow() async throws {
        try await store.requestDownloads([song("a")], waiting: true)
        var next = try await store.nextDownload(LibraryStore.waiting)
        XCTAssertEqual(next, "a")
        next = try await store.nextDownload(LibraryStore.queued)
        XCTAssertNil(next)
        try await store.requestDownloads([song("a")])
        next = try await store.nextDownload(LibraryStore.queued)
        XCTAssertEqual(next, "a")
        next = try await store.nextDownload(LibraryStore.waiting)
        XCTAssertNil(next)
    }

    func testWaitingNeverPutsAQueuedSongBackToWaiting() async throws {
        try await store.requestDownloads([song("a")])
        try await store.requestDownloads([song("a")], waiting: true)
        let next = try await store.nextDownload(LibraryStore.queued)
        XCTAssertEqual(next, "a")
    }

    func testASongFailsForGoodAfterThreeTriesAndAskingAgainRevivesIt() async throws {
        try await store.requestDownloads([song("a")])
        var failed = try await store.failDownload("a")
        XCTAssertFalse(failed)
        failed = try await store.failDownload("a")
        XCTAssertFalse(failed)
        var all = try await states()
        XCTAssertEqual(all, ["a": LibraryStore.queued])
        failed = try await store.failDownload("a")
        XCTAssertTrue(failed)
        all = try await states()
        XCTAssertEqual(all, ["a": LibraryStore.failed])
        let none = try await store.nextDownload(LibraryStore.queued)
        XCTAssertNil(none)
        try await store.requestDownloads([song("a")])
        all = try await states()
        XCTAssertEqual(all, ["a": LibraryStore.queued])
        failed = try await store.failDownload("a")
        XCTAssertFalse(failed, "the count started again")
    }

    func testSkippedSongsAreLeftOutOfTheNextPick() async throws {
        try await store.requestDownloads([song("a"), song("b")])
        var next = try await store.nextDownload(LibraryStore.queued, skip: ["a"])
        XCTAssertEqual(next, "b")
        next = try await store.nextDownload(LibraryStore.queued, skip: ["a", "b"])
        XCTAssertNil(next)
    }

    func testRemovingDownloadsForgetsSongsNothingElsePointsTo() async throws {
        try await store.setLiked(song("a"), true, at: 1)
        try await store.requestDownloads([song("a"), song("b")])
        try await store.removeDownload("a")
        try await store.removeDownload("b")
        var list = try await store.downloads()
        XCTAssertEqual(list.map(\.track.videoId), [])
        let liked = try await store.liked()
        XCTAssertEqual(liked.first?.track.title, "Title a")
        try await store.requestDownloads([song("c")])
        try await store.clearDownloads()
        list = try await store.downloads()
        XCTAssertEqual(list.map(\.track.videoId), [])
    }

    func testADownloadedSongSurvivesEverythingElseLettingGo() async throws {
        try await store.requestDownloads([song("a")])
        try await store.recordListen(song("a"), at: 1)
        try await store.setLiked(song("a"), true, at: 2)
        try await store.clearHistory()
        try await store.setLiked(song("a"), false)
        let list = try await store.downloads()
        XCTAssertEqual(list.first?.track.title, "Title a")
    }

    func testLikedSongsNotOnTheListYetAreTheOnesToDownloadByThemselves() async throws {
        try await store.setLiked(song("a"), true, at: 1)
        try await store.setLiked(song("b"), true, at: 2)
        try await store.setLiked(song("c"), true, at: 3)
        try await store.requestDownloads([song("a")])
        try await store.finishDownload("a", bytes: 1)
        try await store.requestDownloads([song("c")])
        for _ in 0..<3 { _ = try await store.failDownload("c") }
        let wanted = try await store.likedToDownload()
        XCTAssertEqual(wanted.map(\.videoId), ["b"], "done and failed ones are not asked again")
    }
}

final class Counter: @unchecked Sendable {
    private(set) var count = 0

    func bump() { count += 1 }
}

final class LibraryBackupTests: XCTestCase {
    private var from: LibraryStore!
    private var to: LibraryStore!

    private func song(_ id: String) -> TrackRef {
        TrackRef(videoId: id, title: "Title \(id)", artist: "Artist \(id)", thumb: "https://img/\(id)", durMs: 200_000)
    }

    override func setUpWithError() throws {
        from = try LibraryStore(path: ":memory:")
        to = try LibraryStore(path: ":memory:")
    }

    private func fill() async throws {
        try await from.setLiked(song("a"), true, at: 100)
        try await from.setLiked(song("b"), true, at: 200)
        _ = try await from.createPlaylist("Road trip", [song("c"), song("a"), song("d")], at: 50)
        _ = try await from.createPlaylist("Empty", [], at: 60)
        try await from.recordListen(song("a"), at: 10)
        try await from.recordListen(song("e"), at: 20)
        try await from.recordListen(song("a"), at: 30)
    }

    /// What a person sees of a library, to compare two of them.
    private func view(_ store: LibraryStore) async throws -> String {
        var text = ""
        for entry in try await store.liked() { text += "like \(entry.track) \(entry.at)\n" }
        for list in try await store.playlists().sorted(by: { $0.name < $1.name }) {
            text += "list \(list.name) \(try await store.playlistTracks(list.id))\n"
        }
        for entry in try await store.recent() { text += "heard \(entry.track) \(entry.at) \(entry.plays)\n" }
        return text
    }

    func testALibraryWrittenAndReadBackIsTheSame() async throws {
        try await fill()
        let text = LibraryBackup.toJson(try await from.backup(), at: 1234)
        let restored = try await to.restore(try LibraryBackup.fromJson(text))
        XCTAssertEqual(restored, LibraryStore.Restored(liked: 2, playlists: 2, listens: 3))
        let first = try await view(from)
        let second = try await view(to)
        XCTAssertEqual(first, second)
        let trip = try await to.playlists().first { $0.name == "Road trip" }!
        let order = try await to.playlistTracks(trip.id).map(\.videoId)
        XCTAssertEqual(order, ["c", "a", "d"])
    }

    func testRestoringAgainChangesNothing() async throws {
        try await fill()
        let backup = try LibraryBackup.fromJson(LibraryBackup.toJson(try await from.backup(), at: 1))
        _ = try await to.restore(backup)
        let before = try await view(to)
        let again = try await to.restore(backup)
        XCTAssertEqual(again, LibraryStore.Restored(liked: 0, playlists: 0, listens: 0))
        let after = try await view(to)
        XCTAssertEqual(before, after)
    }

    func testRestoringOnThePhoneItCameFromChangesNothing() async throws {
        try await fill()
        let again = try await from.restore(try await from.backup())
        XCTAssertEqual(again, LibraryStore.Restored(liked: 0, playlists: 0, listens: 0))
        let lists = try await from.playlists()
        XCTAssertEqual(lists.count, 2)
    }

    func testWhatIsHereIsKeptAndWhatIsNewIsAdded() async throws {
        try await fill()
        try await to.setLiked(song("a"), true, at: 999) // liked here at another time: that time stays
        try await to.setLiked(song("z"), true, at: 5)
        _ = try await to.createPlaylist("Road trip", [song("d"), song("y")], at: 1)
        let restored = try await to.restore(try await from.backup())

        XCTAssertEqual(restored, LibraryStore.Restored(liked: 1, playlists: 2, listens: 3))
        let liked = try await to.liked().map { "\($0.track.videoId)\($0.at)" }.sorted()
        XCTAssertEqual(liked, ["a999", "b200", "z5"])
        let trip = try await to.playlists().first { $0.name == "Road trip" }!
        // The songs already there stay first; only the missing ones follow
        let order = try await to.playlistTracks(trip.id).map(\.videoId)
        XCTAssertEqual(order, ["d", "y", "c", "a"])
        let lists = try await to.playlists().filter { $0.name == "Road trip" || $0.name == "Empty" }
        XCTAssertEqual(lists.count, 2)
    }

    func testListensOverTheLimitLoseTheOldestByTime() async throws {
        for i in 1...LibraryStore.historyKeep { try await to.recordListen(song("new"), at: 1_000_000 + Int64(i)) }
        let backup = LibraryStore.Backup(liked: [], playlists: [], listens: [LibraryStore.Entry(track: song("old"), at: 5)])
        let restored = try await to.restore(backup)
        XCTAssertEqual(restored.listens, 1)
        // The old listen arrived last but is the oldest, so it is the one to go, and with it its song
        let recent = try await to.recent()
        XCTAssertEqual(recent.map(\.track.videoId), ["new"])
    }

    func testASongIsWrittenOnceHoweverOftenItIsUsed() async throws {
        try await fill()
        let text = LibraryBackup.toJson(try await from.backup(), at: 1)
        XCTAssertEqual(text.components(separatedBy: "\"Title a\"").count - 1, 1)
    }

    func testOtherFilesAreRefused() {
        XCTAssertThrowsError(try LibraryBackup.fromJson("hello"))
        XCTAssertThrowsError(try LibraryBackup.fromJson("{\"a\":1}"))
        XCTAssertThrowsError(try LibraryBackup.fromJson("{\"app\":\"unison\",\"version\":99,\"songs\":{}}"))
    }

    func testBrokenEntriesAreLeftOutAndTheRestIsKept() async throws {
        let text = """
        {"app":"unison","version":1,"songs":{"a":{"title":"A","artist":"x","thumb":null,"durMs":5},"":{"title":"no id"},"b":{"title":""}},
         "liked":[{"id":"a","at":7},{"id":"missing","at":8},{"id":"b","at":9}],
         "playlists":[{"name":"P","songs":["a","nope"]}],"history":[]}
        """
        let backup = try LibraryBackup.fromJson(text)
        XCTAssertEqual(backup.liked.map(\.track.videoId), ["a"])
        XCTAssertNil(backup.liked[0].track.thumb)
        XCTAssertEqual(backup.playlists[0].tracks.map(\.videoId), ["a"])
        _ = try await to.restore(backup)
        let liked = try await to.liked()
        XCTAssertFalse(liked.isEmpty)
    }
}
