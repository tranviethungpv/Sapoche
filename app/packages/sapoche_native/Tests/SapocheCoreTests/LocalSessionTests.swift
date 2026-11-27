import XCTest
@testable import SapocheCore

@MainActor
final class LocalSessionTests: XCTestCase {
    private func track(_ n: Int) -> TrackRef {
        TrackRef(videoId: String(("video\(n)" + "xxxxxxxxxxx").prefix(11)), title: "Song \(n)", artist: "Artist", thumb: nil, durMs: 200_000)
    }

    private func item(_ id: String, _ video: String, _ title: String, durMs: Int64 = 200_000) -> QueueItem {
        QueueItem(id: id, videoId: video, title: title, artist: "x", thumb: nil, durMs: durMs, addedBy: "")
    }

    @MainActor
    private final class Harness {
        let time = VirtualTime()
        let scope = Scope()
        let player: FakePlayer
        var ended: [String] = []
        var saved: [SavedQueue] = []
        var problems: [LocalSession.Problem] = []
        private var counter = 0
        var session: LocalSession!

        init(saved initial: SavedQueue?) {
            player = FakePlayer(time: time)
            var generator = SplitMix(seed: 7)
            session = LocalSession(
                scope: scope, player: player, saved: initial,
                persist: { [weak self] in self?.saved.append($0) },
                problem: { [weak self] in self?.problems.append($0) },
                onQueueEnd: { [weak self] in self?.ended.append($0.title) },
                newId: { [weak self] in
                    self?.counter += 1
                    return "id\(self?.counter ?? 0)"
                },
                random: AnyRandom { generator.next() },
                time: time
            )
            session.attach()
        }

        func step(_ ms: Int64 = 100) async { await time.advance(ms) }
        func titles() -> [String] { session.snapshot.value.queue.map(\.title) }
    }

    private var harnesses: [Harness] = []

    private func harness(_ saved: SavedQueue? = nil) -> Harness {
        let h = Harness(saved: saved)
        harnesses.append(h)
        return h
    }

    override func tearDown() async {
        harnesses.forEach { $0.scope.cancel() }
        harnesses = []
    }

    func testAddingToAnEmptyQueueStartsPlayingTheFirstSong() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2"])
        XCTAssertEqual(h.player.queuedNext?.title, "Song 2", "the next song is ready for a gapless finish")
    }

    func testPlayingAListFromASongKeepsTheSongsBeforeItToGoBackTo() async {
        let h = harness()
        h.session.add([track(9)], next: false)
        await h.step()
        h.session.playList((1...5).map(track), start: 2)
        await h.step()
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 3", "Song 4", "Song 5"], "the old queue is gone")
        XCTAssertEqual(h.session.snapshot.value.index, 2)
        XCTAssertEqual(h.player.loaded?.title, "Song 3")
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.player.queuedNext?.title, "Song 4")
        h.session.next()
        h.session.prev()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 3")
        h.session.prev()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 2", "back goes to the song before the one chosen")
    }

    func testAListPlayedFromAStartOutsideItIsKeptInside() async {
        let h = harness()
        h.session.playList((1...3).map(track), start: 9)
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 3")
        h.session.playList((1...3).map(track), start: -4)
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        h.session.playList([], start: 0)
        XCTAssertEqual(h.session.snapshot.value.queue.count, 3, "nothing to play changes nothing")
    }

    func testPlayingAListWithShuffleOnStartsAtTheSongAndMixesTheRest() async {
        let h = harness()
        h.session.setShuffle(true)
        h.session.playList((1...8).map(track), start: 3)
        await h.step()
        let s = h.session.snapshot.value
        XCTAssertEqual(s.index, 0)
        XCTAssertEqual(s.current?.title, "Song 4")
        XCTAssertEqual(h.player.loaded?.title, "Song 4")
        XCTAssertEqual(Set(h.titles()), Set((1...8).map { "Song \($0)" }))
        XCTAssertEqual(s.queue.count, 8)
        h.session.setShuffle(false)
        XCTAssertEqual(h.titles(), ["Song 4"] + [1, 2, 3, 5, 6, 7, 8].map { "Song \($0)" }, "off puts the rest back in the list's order")
    }

    func testTheEndOfAListPlayedFromTheMiddleWrapsToItsFirstSongWhenRepeatingAll() async {
        let h = harness()
        h.session.setRepeat("all")
        h.session.playList((1...3).map(track), start: 1)
        await h.step()
        h.session.next()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 3")
        h.session.next()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
    }

    func testAddingWhilePlayingDoesNotDisturbIt() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step()
        let loads = h.player.prepareCount
        h.session.add([track(2), track(3)], next: false)
        await h.step()
        XCTAssertEqual(h.player.prepareCount, loads)
        XCTAssertEqual(h.player.queuedNext?.title, "Song 2")
        XCTAssertEqual(h.session.snapshot.value.queue.count, 3)
    }

    func testASongAlreadyWaitingInTheQueueIsNotAddedAgain() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step()
        h.session.add([track(2)], next: false)
        h.session.add([track(2), track(3), track(3)], next: false)
        await h.step()
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 3"])
        XCTAssertTrue(h.problems.isEmpty)
    }

    func testASongThatWasPlayedCanBeAddedAgain() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.next()
        await h.step()
        h.session.add([track(1)], next: false)
        await h.step()
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 1"])
    }

    func testPlayNextGoesRightAfterTheCurrentSong() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.add([track(3)], next: true)
        await h.step()
        XCTAssertEqual(h.titles(), ["Song 1", "Song 3", "Song 2"])
        XCTAssertEqual(h.player.queuedNext?.title, "Song 3")
    }

    func testNextMovesAlongAndTheLastSongEndsTheQueue() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.next()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
        XCTAssertEqual(h.session.snapshot.value.index, 1)
        h.player.onEnded?()
        await h.step()
        XCTAssertFalse(h.player.playing)
        XCTAssertNil(h.player.loaded, "the player is let go of")
        XCTAssertTrue(h.session.snapshot.value.finished)
    }

    func testTheQueueRunningOutIsAnnouncedWithTheLastSongOnce() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.next()
        await h.step()
        XCTAssertEqual(h.ended, [], "a song is still to come")
        h.session.next()
        await h.step()
        XCTAssertEqual(h.ended, ["Song 2"])
    }

    func testAnEndReportedWhileNothingOfOursIsLoadedChangesNothing() async {
        // What a restarted player says when it has nothing to play
        let h = harness(SavedQueue(queue: [item("q1", "video1xxxxx", "Song 1")], index: 0, repeatMode: "off", positionMs: 30_000, finished: false))
        h.player.onEnded?()
        await h.step()
        XCTAssertFalse(h.session.snapshot.value.finished)
        XCTAssertEqual(h.ended, [])
        XCTAssertEqual(h.session.restoredPositionMs, 30_000, "it still resumes where it was")
    }

    func testASongEndingByItselfAtTheEndOfTheQueueIsAnnounced() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step()
        h.player.onEnded?()
        await h.step()
        XCTAssertEqual(h.ended, ["Song 1"])
    }

    func testRepeatingOrRemovingTheLastSongDoesNotAnnounceAnEnd() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step()
        h.session.setRepeat("all")
        h.player.onEnded?()
        await h.step()
        XCTAssertEqual(h.ended, [], "repeat all starts over")
        h.session.setRepeat("off")
        h.session.remove(h.session.snapshot.value.queue.last!.id)
        await h.step()
        XCTAssertEqual(h.ended, [], "the person took it away")
    }

    func testSongsAddedAfterTheEndStartPlaying() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step()
        h.session.next()
        await h.step()
        XCTAssertTrue(h.session.snapshot.value.finished)
        h.session.add([track(2), track(3)], next: false)
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
        XCTAssertTrue(h.player.playing)
    }

    func testPlayAfterTheQueueFinishedStartsItAgainFromTheTop() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.next()
        await h.step()
        h.player.onEnded?()
        await h.step()
        h.session.play()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        XCTAssertTrue(h.player.playing)
        XCTAssertFalse(h.session.snapshot.value.finished)
    }

    func testRepeatAllWrapsAroundAndRepeatOnePlaysTheSameSongAgain() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.setRepeat("all")
        h.session.next()
        await h.step()
        h.player.onEnded?()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 1")

        h.session.setRepeat("one")
        await h.step()
        XCTAssertNil(h.player.queuedNext, "repeating one song has no successor, or the player would move on by itself")
        let loads = h.player.prepareCount
        h.player.onEnded?()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        XCTAssertEqual(h.player.prepareCount, loads + 1)
    }

    func testThePlayerMovingOnByItselfIsFollowedAndTheNextSongIsPrepared() async {
        let h = harness()
        h.session.add([track(1), track(2), track(3)], next: false)
        await h.step()
        h.player.autoAdvance()
        await h.step()
        XCTAssertEqual(h.session.snapshot.value.index, 1)
        XCTAssertEqual(h.player.queuedNext?.title, "Song 3")
    }

    func testPreviousRestartsASongThatHasPlayedAWhileAndGoesBackWhenItHasJustBegun() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.next()
        await h.step(10_000)
        h.session.prev()
        await h.step()
        XCTAssertEqual(h.session.snapshot.value.index, 1, "still on the second song")
        XCTAssertLessThan(h.player.position, 1000, "and back at its start")
        h.session.prev()
        await h.step()
        XCTAssertEqual(h.session.snapshot.value.index, 0)
    }

    func testSwappingTheSongThatPlaysLoadsTheOtherReleaseFromTheSameMoment() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        await h.step(5_000)
        let before = h.player.position
        h.session.swap("id1", TrackRef(videoId: "videoSwappd", title: "Song 1 (Video)", artist: "Artist", thumb: nil, durMs: 210_000))
        await h.step()
        XCTAssertEqual(h.player.loaded?.videoId, "videoSwappd")
        XCTAssertEqual(h.player.loaded?.id, "id1", "the same place in the queue")
        XCTAssertGreaterThanOrEqual(h.player.position, before, "from where it was, not from the start")
        XCTAssertTrue(h.player.playing, "still playing")
        XCTAssertEqual(h.titles(), ["Song 1 (Video)", "Song 2"])
        XCTAssertEqual(h.player.queuedNext?.title, "Song 2")
    }

    func testSwappingASongThatIsBufferingStillPlaysTheOtherRelease() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step()
        h.player.playing = false // rebuffering: not heard, but not paused by anybody
        h.session.swap("id1", TrackRef(videoId: "videoSwappd", title: "Song 1 (Video)", artist: "Artist", thumb: nil, durMs: 210_000))
        await h.step()
        XCTAssertEqual(h.player.loaded?.videoId, "videoSwappd")
        XCTAssertTrue(h.player.playing)
    }

    func testSwappingASongThatIsPausedKeepsItPaused() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step()
        h.session.pause()
        await h.step()
        h.session.swap("id1", TrackRef(videoId: "videoSwappd", title: "Song 1 (Video)", artist: "Artist", thumb: nil, durMs: 210_000))
        await h.step()
        XCTAssertEqual(h.player.loaded?.videoId, "videoSwappd")
        XCTAssertFalse(h.player.playing)
    }

    func testSwappingASongStillToComeChangesItQuietly() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        let loads = h.player.prepareCount
        h.session.swap("id2", TrackRef(videoId: "videoSwappd", title: "Song 2 (Video)", artist: "Artist", thumb: nil, durMs: 210_000))
        await h.step()
        XCTAssertEqual(h.player.prepareCount, loads, "what plays is not touched")
        XCTAssertEqual(h.player.queuedNext?.videoId, "videoSwappd", "and the next one is the other release")
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2 (Video)"])
    }

    func testSwappingForTheSameReleaseOrAnUnknownSongDoesNothing() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step()
        let loads = h.player.prepareCount
        h.session.swap("id1", track(1))
        h.session.swap("nope", track(5))
        await h.step()
        XCTAssertEqual(h.player.prepareCount, loads)
        XCTAssertEqual(h.titles(), ["Song 1"])
    }

    func testRemovingTheCurrentSongPlaysTheOneAfterIt() async {
        let h = harness()
        h.session.add([track(1), track(2), track(3)], next: false)
        await h.step()
        h.session.remove("id1")
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.titles(), ["Song 2", "Song 3"])
        XCTAssertEqual(h.session.snapshot.value.index, 0)
    }

    func testRemovingAnEarlierSongKeepsTheCurrentOne() async {
        let h = harness()
        h.session.add([track(1), track(2), track(3)], next: false)
        await h.step()
        h.session.next()
        await h.step()
        h.session.remove("id1")
        await h.step()
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 2")
        XCTAssertEqual(h.session.snapshot.value.index, 0)
        XCTAssertTrue(h.player.playing)
    }

    func testRemovingTheOnlyOrTheLastSongStopsCleanly() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.next()
        await h.step()
        h.session.remove("id2")
        await h.step()
        XCTAssertTrue(h.session.snapshot.value.finished)
        XCTAssertNil(h.player.loaded)
        h.session.remove("id1")
        await h.step()
        XCTAssertEqual(h.titles(), [])
        XCTAssertFalse(h.session.snapshot.value.finished)
    }

    func testMovingASongKeepsTheCurrentOneCurrent() async {
        let h = harness()
        h.session.add([track(1), track(2), track(3)], next: false)
        await h.step()
        h.session.move("id3", toIndex: 0)
        await h.step()
        XCTAssertEqual(h.titles(), ["Song 3", "Song 1", "Song 2"])
        XCTAssertEqual(h.session.snapshot.value.index, 1)
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 1")
        XCTAssertTrue(h.player.playing)
    }

    func testShuffleMixesOnlyWhatIsToCome() async {
        let h = harness()
        h.session.add((1...8).map(track), next: false)
        await h.step()
        h.session.next()
        await h.step()
        let before = h.titles()
        h.session.shuffle()
        await h.step()
        let after = h.titles()
        XCTAssertEqual(Array(before.prefix(2)), Array(after.prefix(2)), "what was played and the current song stay put")
        XCTAssertEqual(Set(before.dropFirst(2)), Set(after.dropFirst(2)))
        XCTAssertNotEqual(before, after, "the rest was mixed")
        XCTAssertEqual(h.player.queuedNext?.title, after[2], "and the successor follows the new order")
    }

    func testShuffleAsAModeMixesWhatIsToComeAndOffPutsItBackInOrder() async {
        let h = harness()
        h.session.add((1...8).map(track), next: false)
        await h.step()
        h.session.next()
        await h.step()
        let before = h.titles()
        h.session.setShuffle(true)
        await h.step()
        XCTAssertTrue(h.session.snapshot.value.shuffle)
        let mixed = h.titles()
        XCTAssertEqual(Array(before.prefix(2)), Array(mixed.prefix(2)), "what was played and the current song stay put")
        XCTAssertEqual(Set(before.dropFirst(2)), Set(mixed.dropFirst(2)))
        XCTAssertNotEqual(before, mixed, "the rest was mixed")
        XCTAssertEqual(h.player.queuedNext?.title, mixed[2], "and the successor follows the new order")

        h.session.setShuffle(false)
        await h.step()
        XCTAssertFalse(h.session.snapshot.value.shuffle)
        XCTAssertEqual(before, h.titles(), "turning it off puts the songs back in the order they had")
    }

    func testSongsAddedWhileShuffleIsOnKeepTheirOrderAheadOfTheShuffledList() async {
        let h = harness()
        h.session.add((1...6).map(track), next: false)
        await h.step()
        h.session.setShuffle(true)
        await h.step()
        h.session.add([track(7)], next: false)
        h.session.add([track(8)], next: true)
        await h.step()
        let titles = h.titles()
        XCTAssertEqual(Array(titles.prefix(3)), ["Song 1", "Song 8", "Song 7"], "queued songs stay in order right after the current song")

        h.session.setShuffle(false)
        await h.step()
        XCTAssertEqual(h.titles(), ["Song 1", "Song 8", "Song 7", "Song 2", "Song 3", "Song 4", "Song 5", "Song 6"])
    }

    func testShuffleModeSurvivesClearingTheQueueAndIsSaved() async {
        let h = harness()
        h.session.add((1...4).map(track), next: false)
        await h.step()
        h.session.setShuffle(true)
        await h.step()
        h.session.clear()
        await h.step()
        XCTAssertTrue(h.session.snapshot.value.shuffle, "clearing the queue leaves the mode as it was")
        XCTAssertEqual(h.saved.last?.shuffle, true)
    }

    func testShuffleAfterTheQueueFinishedMixesEverythingAndPlaysFromTheTop() async {
        let h = harness()
        h.session.add((1...6).map(track), next: false)
        await h.step()
        h.session.setRepeat("off")
        for _ in 0..<6 {
            h.player.onEnded?()
            await h.step()
        }
        XCTAssertTrue(h.session.snapshot.value.finished)
        h.session.shuffle()
        await h.step()
        XCTAssertFalse(h.session.snapshot.value.finished)
        XCTAssertEqual(h.session.snapshot.value.index, 0)
        XCTAssertTrue(h.player.playing)
    }

    func testJumpPlaysTheChosenSong() async {
        let h = harness()
        h.session.add([track(1), track(2), track(3)], next: false)
        await h.step()
        h.session.jump("id3")
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 3")
        XCTAssertEqual(h.session.snapshot.value.index, 2)
    }

    func testClearEmptiesTheQueueAndSilencesThePlayer() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.clear()
        await h.step()
        XCTAssertEqual(h.titles(), [])
        XCTAssertFalse(h.player.playing)
        XCTAssertNil(h.player.loaded)
    }

    func testDroppingPlayedSongsKeepsTheOnePlayingAndThoseToCome() async {
        let h = harness()
        h.session.add([track(1), track(2), track(3), track(4)], next: false)
        await h.step()
        h.session.jump(h.session.snapshot.value.queue[2].id)
        await h.step()
        h.session.dropPlayed(10)
        await h.step()
        XCTAssertEqual(h.titles(), ["Song 3", "Song 4"])
        XCTAssertEqual(h.session.snapshot.value.index, 0)
        XCTAssertEqual(h.player.loaded?.title, "Song 3")
    }

    func testOnceTheQueueHasFinishedAllOfItMayBeDroppedOldestFirst() async {
        let h = harness()
        h.session.add([track(1), track(2), track(3)], next: false)
        await h.step()
        h.session.jump(h.session.snapshot.value.queue[2].id)
        await h.step()
        h.player.onEnded?()
        await h.step()
        XCTAssertTrue(h.session.snapshot.value.finished)
        h.session.dropPlayed(2)
        await h.step()
        XCTAssertEqual(h.titles(), ["Song 3"])
        XCTAssertEqual(h.session.snapshot.value.index, 0)
        h.session.dropPlayed(0)
        h.session.dropPlayed(-5)
        XCTAssertEqual(h.titles(), ["Song 3"])
    }

    func testARestoredQueueLoadsNothingAndPlaysNothingUntilAsked() async {
        let song = item("a", "aaaaaaaaaaa", "One")
        let other = item("b", "bbbbbbbbbbb", "Two")
        let h = harness(SavedQueue(queue: [song, other], index: 1, repeatMode: "all", positionMs: 42_000))
        await h.step()
        XCTAssertNil(h.player.loaded)
        XCTAssertFalse(h.player.playing)
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Two")
        XCTAssertEqual(h.session.snapshot.value.repeatMode, "all")
        XCTAssertEqual(h.session.restoredPositionMs, 42_000)

        h.session.play()
        await h.step()
        XCTAssertEqual(h.player.loaded, other)
        XCTAssertTrue(h.player.playing)
        XCTAssertGreaterThanOrEqual(h.player.position, 42_000, "resumes where it was left, was \(h.player.position)")
        XCTAssertNil(h.session.restoredPositionMs)
    }

    func testASavedQueueWithABadIndexOrRepeatIsPutRight() {
        let h = harness(SavedQueue(queue: [item("a", "aaaaaaaaaaa", "One")], index: 9, repeatMode: "sideways"))
        XCTAssertEqual(h.session.snapshot.value.index, 0)
        XCTAssertEqual(h.session.snapshot.value.repeatMode, "off")
    }

    func testChangesAndPausesAreSavedWithThePosition() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step(5000)
        h.session.pause()
        let saved = h.saved.last!
        XCTAssertEqual(saved.queue.map(\.title), ["Song 1", "Song 2"])
        XCTAssertEqual(saved.index, 0)
        XCTAssertTrue((4000...6000).contains(saved.positionMs), "position was \(saved.positionMs)")
    }

    func testARoomTakingOverSilencesThePlayerAndComingBackResumesWhereItWas() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step(8000)
        h.session.detach()
        XCTAssertFalse(h.player.playing)
        XCTAssertNil(h.player.loaded)
        let position = h.saved.last!.positionMs
        XCTAssertTrue((7000...9000).contains(position))

        h.session.attach()
        h.session.play()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        XCTAssertGreaterThanOrEqual(h.player.position, position)
    }

    func testAStreamThatBreaksIsLoadedAgainWhereItStopped() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step(9000)
        let loads = h.player.prepareCount
        h.player.onError?(NSError(domain: "t", code: 403))
        await h.step()
        XCTAssertEqual(h.player.prepareCount, loads + 1)
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        XCTAssertGreaterThanOrEqual(h.player.position, 9000, "was \(h.player.position)")
        XCTAssertTrue(h.player.playing)
    }

    func testAStreamThatKeepsBreakingIsGivenUpOnAndTheNextSongPlays() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step(1000)
        for _ in 0..<3 {
            h.player.onError?(NSError(domain: "t", code: 403))
            await h.step()
        }
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        h.player.onError?(NSError(domain: "t", code: 403))
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
        XCTAssertEqual(h.problems.filter { $0.title == "Song 1" }.map(\.kind), [.broken],
                       "a stream that keeps breaking is told as the connection's doing, not as a song YouTube will not give out")
    }

    func testANewSongInThePlaceOfOneThatBrokeGetsAllItsTries() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step(1000)
        h.player.onError?(NSError(domain: "t", code: 403))
        await h.step()
        // A new list starts where the old one was, at the top of the queue
        h.session.clear()
        h.session.add([track(2)], next: false)
        await h.step(1000)
        for _ in 0..<3 {
            h.player.onError?(NSError(domain: "t", code: 403))
            await h.step()
        }
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
        XCTAssertFalse(h.problems.contains { $0.title == "Song 2" }, "the tries of Song 1 are not counted for it")
    }

    func testAskingToPlayTwiceWhileTheSongIsLoadingLoadsItOnce() async {
        let h = harness(SavedQueue(queue: [item("a", "aaaaaaaaaaa", "One")]))
        h.player.prepareDelayMs = 2000
        h.session.play()
        await h.step(500)
        h.session.play()
        // Two seconds after the first press: a restart at the second press would still be loading
        await h.step(1700)
        XCTAssertTrue(h.player.playing, "the second press must not cancel and restart the load")
        XCTAssertEqual(h.player.prepareCount, 1)
    }

    func testPausingWhileTheSongIsLoadingLeavesItPausedWhenItIsReady() async {
        let song = item("a", "aaaaaaaaaaa", "One")
        let h = harness(SavedQueue(queue: [song]))
        h.player.prepareDelayMs = 2000
        h.session.play()
        await h.step(500)
        h.session.pause()
        await h.step(3000)
        XCTAssertEqual(h.player.loaded, song)
        XCTAssertFalse(h.player.playing)
        h.session.play()
        await h.step(100)
        XCTAssertTrue(h.player.playing)
    }

    func testASongThatCannotBeLoadedIsReportedAndLeavesNothingPlaying() async {
        let h = harness()
        h.player.failPrepare = true
        h.session.add([track(1)], next: false)
        await h.step(LocalSession.retryAfterMs + 500)
        XCTAssertTrue(h.problems.contains { $0.title == "Song 1" })
        XCTAssertFalse(h.player.playing)
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 1", "it stays in the queue to try again")
    }

    func testASongIsShownAsOnItsWayUntilItPlays() async {
        let h = harness()
        h.player.prepareDelayMs = 3000
        h.session.add([track(1)], next: false)
        await h.step(1000)
        XCTAssertTrue(h.session.snapshot.value.loading, "the screen must show something is happening")
        XCTAssertFalse(h.player.playing)
        await h.step(2500)
        XCTAssertFalse(h.session.snapshot.value.loading)
        XCTAssertTrue(h.player.playing)
    }

    func testPausingWhileASongLoadsNoLongerShowsItAsOnItsWay() async {
        let h = harness()
        h.player.prepareDelayMs = 3000
        h.session.add([track(1)], next: false)
        await h.step(1000)
        h.session.pause()
        XCTAssertFalse(h.session.snapshot.value.loading)
        h.session.play()
        XCTAssertTrue(h.session.snapshot.value.loading)
    }

    func testASlowLoadIsSaidToBeSlowOnce() async {
        let h = harness()
        h.player.prepareDelayMs = 20_000
        h.session.add([track(1)], next: false)
        await h.step(7000)
        XCTAssertTrue(h.problems.isEmpty, "not slow yet")
        await h.step(2000)
        XCTAssertEqual(h.problems, [LocalSession.Problem(kind: .slow, title: "Song 1")])
        await h.step(15_000)
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.problems.count, 1)
    }

    func testTryingASlowSongAgainStartsFromANewStreamAddress() async {
        let h = harness()
        h.player.prepareDelayMs = 20_000
        h.session.add([track(1), track(2)], next: false)
        await h.step(9000)
        XCTAssertEqual(h.problems.count, 1, "said to be slow")
        XCTAssertTrue(h.player.refreshed.isEmpty, "waiting alone keeps the address")
        h.session.jump(h.session.snapshot.value.queue[0].id)
        await h.step()
        XCTAssertEqual(h.player.refreshed, [track(1).videoId])
    }

    func testASongTappedAgainAfterAFailureStartsFromANewStreamAddressAlsoFromANewQueue() async {
        let h = harness()
        h.player.failPrepare = true
        h.session.add([track(1)], next: false)
        await h.step(LocalSession.retryAfterMs + 500)
        XCTAssertEqual(h.problems.map(\.kind), [.failed])
        h.player.failPrepare = false
        h.player.refreshed = []
        h.session.clear()
        h.session.add([track(1)], next: false) // the list was tapped: the same song with another queue id
        await h.step()
        XCTAssertEqual(h.player.refreshed, [track(1).videoId])
        XCTAssertTrue(h.player.playing)

        // It played: the next time is an ordinary load
        h.session.add([track(2)], next: false)
        h.session.jump(h.session.snapshot.value.queue[1].id)
        h.session.jump(h.session.snapshot.value.queue[0].id)
        await h.step()
        XCTAssertEqual(h.player.refreshed.count, 1)
    }

    func testALoadThatIsReplacedIsNotCalledSlow() async {
        let h = harness()
        h.player.prepareDelayMs = 5000
        h.session.add([track(1), track(2)], next: false)
        await h.step(4000)
        h.session.next() // the first load is dropped before it gets slow
        await h.step(10_000)
        XCTAssertTrue(h.problems.isEmpty, "was \(h.problems)")
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
    }

    func testASongYouTubeWillNotPlayIsSkippedAndThePersonTold() async {
        let h = harness()
        h.player.failWith = { $0.title == "Song 1" ? LoadFailure(reason: .unplayable, message: "removed") : nil }
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.problems.map(\.kind), [.skipped])
        XCTAssertEqual(h.problems.first?.title, "Song 1")
    }

    func testSkippingStopsAfterAFewSongsInARowThatWillNotPlay() async {
        let h = harness()
        h.player.failWith = { _ in LoadFailure(reason: .unplayable, message: "YouTube changed") }
        h.session.add((1...6).map(track), next: false)
        await h.step()
        XCTAssertEqual(h.problems.map(\.kind), [.skipped, .skipped, .unplayable])
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 3", "it stops instead of running through the queue")
        XCTAssertFalse(h.player.playing)
        XCTAssertFalse(h.session.snapshot.value.loading)
    }

    func testWithoutANetworkTheSongIsKeptNothingLoadsOnAndPlayTriesAgain() async {
        let h = harness()
        h.player.failWith = { _ in LoadFailure(reason: .offline, message: "no network") }
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        XCTAssertEqual(h.problems.map(\.kind), [.offline])
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 1", "not skipped: the next song would fail as well")
        XCTAssertNil(h.player.loaded, "the player was stopped, so nothing starts by itself later")
        XCTAssertFalse(h.session.snapshot.value.loading)

        h.player.failWith = nil
        h.session.play()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        XCTAssertTrue(h.player.playing)
    }

    func testAnyOtherFailureToLoadSaysSoWithWhatWentWrongAndKeepsTheSongWhenThereIsNothingToGoOnTo() async {
        let h = harness()
        h.player.failPrepare = true
        h.session.add([track(1)], next: false)
        await h.step(LocalSession.retryAfterMs + 500)
        XCTAssertEqual(h.problems.map(\.kind), [.failed])
        XCTAssertTrue(h.problems.first?.detail.contains("cannot load") == true, "was \(h.problems)")
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 1")
        XCTAssertTrue(h.ended.isEmpty, "a failure to load is not the end of the queue, which would start autoplay")
        XCTAssertFalse(h.session.snapshot.value.loading)
    }

    /// Fails the first [times] tries of a song, then loads it.
    private func failFirst(_ h: Harness, _ times: Int, reason: LoadFailure.Reason? = nil) {
        var left = times
        h.player.failWith = { _ in
            guard left > 0 else { return nil }
            left -= 1
            if let reason { return LoadFailure(reason: reason, message: "x") }
            return NSError(domain: "blip", code: 1, userInfo: [NSLocalizedDescriptionKey: "blip"])
        }
    }

    func testASongThatDidNotLoadGetsOneMoreTryFromANewAddressAndPlaysIfThatWorks() async {
        let h = harness()
        failFirst(h, 1)
        h.session.add([track(1), track(2)], next: false)
        await h.step(500)
        XCTAssertNil(h.player.loaded)
        XCTAssertTrue(h.session.snapshot.value.loading, "it shows that something is going on while it waits")
        XCTAssertTrue(h.problems.isEmpty, "a blip is not said to the person")
        await h.step(LocalSession.retryAfterMs)
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.player.refreshed, [track(1).videoId], "the second try starts from a new stream address")
        XCTAssertTrue(h.problems.isEmpty)
        XCTAssertEqual(h.player.prepareAttempts, 2)
    }

    func testASongThatFailsTwiceIsSkippedToTheNext() async {
        let h = harness()
        h.player.failWith = { $0.title == "Song 1" ? NSError(domain: "blip", code: 1) : nil }
        h.session.add([track(1), track(2)], next: false)
        await h.step(LocalSession.retryAfterMs + 500)
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.problems.map(\.kind), [.broken])
        XCTAssertEqual(h.problems.map(\.title), ["Song 1"])
    }

    func testSkippingBecauseSongsFailToLoadStopsAfterAFewInARowWithTheFailureSaid() async {
        let h = harness()
        h.player.failWith = { _ in NSError(domain: "blip", code: 1) }
        h.session.add((1...6).map(track), next: false)
        await h.step((LocalSession.retryAfterMs + 500) * 4)
        XCTAssertEqual(h.problems.map(\.kind), [.broken, .broken, .failed])
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 3")
        XCTAssertFalse(h.player.playing)
        XCTAssertFalse(h.session.snapshot.value.loading)
        XCTAssertEqual(h.player.prepareAttempts, 6, "two tries for each of three songs, and no more")
    }

    func testSongsThatWillNotPlayAndSongsThatDidNotLoadCountTogetherTowardsStopping() async {
        let h = harness()
        h.player.failWith = { item -> Error? in
            if item.title == "Song 2" { return NSError(domain: "blip", code: 1) }
            return LoadFailure(reason: .unplayable, message: "gone")
        }
        h.session.add((1...6).map(track), next: false)
        await h.step((LocalSession.retryAfterMs + 500) * 2)
        XCTAssertEqual(h.problems.map(\.kind), [.skipped, .broken, .unplayable])
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 3")
    }

    func testTheLastSongOfTheListIsNotSkippedWhenItFailsSoNoQueueEndsBecauseOfANetwork() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        failFirst(h, 2)
        h.session.next()
        await h.step(LocalSession.retryAfterMs + 500)
        XCTAssertEqual(h.problems.last?.kind, .failed)
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 2")
        XCTAssertFalse(h.session.snapshot.value.finished)
        XCTAssertTrue(h.ended.isEmpty)
    }

    func testRepeatingAllWithASingleSongThatFailsDoesNotLoopThroughIt() async {
        let h = harness()
        h.session.add([track(1)], next: false)
        await h.step()
        h.session.setRepeat("all")
        failFirst(h, 2)
        h.session.jump(h.session.snapshot.value.queue[0].id)
        await h.step(LocalSession.retryAfterMs + 500)
        XCTAssertEqual(h.problems.last?.kind, .failed)
        XCTAssertEqual(h.player.prepareAttempts - 1, 2, "two tries, and no looping round to the same song")
    }

    func testRepeatingAllGoesRoundToTheFirstSongWhenTheLastFails() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.setRepeat("all")
        h.player.failWith = { $0.title == "Song 2" ? NSError(domain: "blip", code: 1) : nil }
        h.session.next()
        await h.step(LocalSession.retryAfterMs + 500)
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        XCTAssertEqual(h.problems.last?.kind, .broken)
    }

    func testPausingWhileTheRetryWaitsLeavesItPausedAndSaysNothing() async {
        let h = harness()
        failFirst(h, 1)
        h.session.add([track(1), track(2)], next: false)
        await h.step(500)
        h.session.pause()
        await h.step(LocalSession.retryAfterMs * 2)
        XCTAssertTrue(h.problems.isEmpty, "was \(h.problems)")
        XCTAssertNil(h.player.loaded, "nothing starts later by itself")
        XCTAssertFalse(h.player.playing)
        XCTAssertFalse(h.session.snapshot.value.loading)
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 1", "no skipping to the next either")

        h.session.play()
        await h.step()
        XCTAssertTrue(h.player.playing, "play starts it again, from a new address")
        XCTAssertEqual(h.player.refreshed, [track(1).videoId])
    }

    func testAnotherSongChosenWhileTheRetryWaitsDropsTheRetry() async {
        let h = harness()
        h.player.failWith = { $0.title == "Song 1" ? NSError(domain: "blip", code: 1) : nil }
        h.session.add([track(1), track(2), track(3)], next: false)
        await h.step(500)
        h.session.jump(h.session.snapshot.value.queue[2].id)
        await h.step(LocalSession.retryAfterMs * 3)
        XCTAssertEqual(h.player.loaded?.title, "Song 3")
        XCTAssertTrue(h.problems.isEmpty)
        XCTAssertEqual(h.player.prepareAttempts, 2, "the dropped song was not tried a second time")
    }

    /// Random taps among random failures. With [transientOnly] every failure is a blip, which must never end the queue: the
    /// queue ends only when the person goes past its last song. Whatever the failures, it settles, when left alone on a good
    /// network, with nothing still loading.
    private func checkInvariant(_ s: LocalSession.Snapshot) {
        if s.queue.isEmpty {
            XCTAssertEqual(s.index, 0)
            XCTAssertTrue(s.queued.isEmpty)
            XCTAssertFalse(s.finished)
            return
        }
        XCTAssertTrue(s.queue.indices.contains(s.index))
        if s.finished {
            XCTAssertTrue(s.queued.isEmpty)
            XCTAssertFalse(s.queue.contains(where: \.auto))
            return
        }
        let before = s.queue.prefix(s.index + 1)
        let after = s.queue.dropFirst(s.index + 1)
        XCTAssertFalse(before.contains { s.queued.contains($0.id) })
        XCTAssertFalse(before.contains(where: \.auto))
        let afterIds = Set(after.map(\.id))
        XCTAssertTrue(s.queued.isSubset(of: afterIds))
        var tier = 0
        for item in after {
            let itemTier: Int
            if s.queued.contains(item.id) {
                XCTAssertFalse(item.auto)
                itemTier = 0
            } else if !item.auto {
                itemTier = 1
            } else {
                itemTier = 2
            }
            XCTAssertGreaterThanOrEqual(itemTier, tier)
            tier = itemTier
        }
    }

    func testQueuedSongsPlayBeforeTheRestOfTheListAndPlayNextGoesToTheFrontOfThem() async {
        let h = harness()
        h.session.playList((1...5).map(track), start: 1, label: "Lofi Chill")
        await h.step()
        h.session.add([track(8)], next: false)
        h.session.add([track(9)], next: false)
        h.session.add([track(7)], next: true)
        await h.step()
        let s = h.session.snapshot.value
        checkInvariant(s)
        XCTAssertEqual(s.label, "Lofi Chill")
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 7", "Song 8", "Song 9", "Song 3", "Song 4", "Song 5"])
        XCTAssertEqual(Set(s.queue.filter { s.queued.contains($0.id) }.map(\.title)), ["Song 7", "Song 8", "Song 9"])
        XCTAssertEqual(h.player.queuedNext?.title, "Song 7")
    }

    func testStartingANewListKeepsUnplayedQueuedSongsRightAfterTheChosenSong() async {
        let h = harness()
        h.session.playList((1...4).map(track), start: 0, label: "Old")
        await h.step()
        h.session.add([track(8), track(9)], next: false)
        h.session.next()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 8")
        h.session.playList((10...12).map(track), start: 1, label: "New Album")
        await h.step()
        let s = h.session.snapshot.value
        checkInvariant(s)
        XCTAssertEqual(s.label, "New Album")
        XCTAssertEqual(h.titles(), ["Song 10", "Song 11", "Song 9", "Song 12"])
        XCTAssertEqual(s.index, 1)
        XCTAssertEqual(h.player.loaded?.title, "Song 11")
        XCTAssertEqual(s.queue.filter { s.queued.contains($0.id) }.map(\.title), ["Song 9"])
    }

    func testShufflingOnlyMixesTheListAndLeavesQueuedSongsInOrder() async {
        let h = harness()
        h.session.playList((1...8).map(track), start: 0, label: "Mix")
        await h.step()
        h.session.add([track(20), track(21)], next: false)
        h.session.setShuffle(true)
        await h.step()
        checkInvariant(h.session.snapshot.value)
        XCTAssertEqual(Array(h.titles().prefix(3)), ["Song 1", "Song 20", "Song 21"])
        h.session.shuffle()
        XCTAssertEqual(Array(h.titles().prefix(3)), ["Song 1", "Song 20", "Song 21"])
        h.session.setShuffle(false)
        XCTAssertEqual(h.titles(), ["Song 1", "Song 20", "Song 21", "Song 2", "Song 3", "Song 4", "Song 5", "Song 6", "Song 7", "Song 8"])
    }

    func testPlayedQueuedSongsStayInHistoryForBackButRepeatAllLoopsOnlyTheListAndRepeatOneRepeatsAQueuedSong() async {
        let h = harness()
        h.session.playList((1...3).map(track), start: 0)
        await h.step()
        h.session.add([track(9)], next: false)
        h.session.setRepeat("one")
        h.session.next()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 9")
        XCTAssertTrue(h.session.snapshot.value.queued.isEmpty)
        h.player.onEnded?()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 9")

        h.session.setRepeat("all")
        h.session.next()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
        h.session.prev()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 9")
        h.session.next()
        h.session.next()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 3")
        h.session.next()
        await h.step()
        XCTAssertEqual(h.player.loaded?.title, "Song 1")
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 3"])
    }

    func testJumpingToASongOfTheListKeepsQueuedSongsWaitingRightAfterIt() async {
        let h = harness()
        h.session.playList((1...5).map(track), start: 0)
        await h.step()
        h.session.add([track(8), track(9)], next: false)
        let song4 = h.session.snapshot.value.queue.first { $0.title == "Song 4" }!.id
        h.session.jump(song4)
        await h.step()
        let s = h.session.snapshot.value
        checkInvariant(s)
        XCTAssertEqual(h.player.loaded?.title, "Song 4")
        XCTAssertEqual(s.index, 3)
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 3", "Song 4", "Song 8", "Song 9", "Song 5"])
        XCTAssertEqual(s.queue.filter { s.queued.contains($0.id) }.map(\.title), ["Song 8", "Song 9"])
    }

    func testJumpingToAQueuedSongSkipsEarlierQueuedSongsAndKeepsTheListWaiting() async {
        let h = harness()
        h.session.playList((1...3).map(track), start: 0)
        await h.step()
        h.session.add([track(7), track(8), track(9)], next: false)
        let song8 = h.session.snapshot.value.queue.first { $0.title == "Song 8" }!.id
        h.session.jump(song8)
        await h.step()
        let s = h.session.snapshot.value
        checkInvariant(s)
        XCTAssertEqual(h.player.loaded?.title, "Song 8")
        XCTAssertEqual(s.index, 2)
        XCTAssertEqual(h.titles(), ["Song 1", "Song 7", "Song 8", "Song 9", "Song 2", "Song 3"])
        XCTAssertEqual(s.queue.filter { s.queued.contains($0.id) }.map(\.title), ["Song 9"])
    }

    func testMovingASongBetweenTheTwoGroupsChangesWhichGroupItBelongsTo() async {
        let h = harness()
        h.session.playList((1...4).map(track), start: 0)
        await h.step()
        h.session.add([track(8), track(9)], next: false)
        let id8 = h.session.snapshot.value.queue.first { $0.title == "Song 8" }!.id
        h.session.move(id8, toIndex: 3, queued: false)
        checkInvariant(h.session.snapshot.value)
        XCTAssertEqual(h.titles(), ["Song 1", "Song 9", "Song 2", "Song 8", "Song 3", "Song 4"])
        XCTAssertEqual(h.session.snapshot.value.queue.filter { h.session.snapshot.value.queued.contains($0.id) }.map(\.title), ["Song 9"])

        let id3 = h.session.snapshot.value.queue.first { $0.title == "Song 3" }!.id
        h.session.move(id3, toIndex: 1, queued: true)
        checkInvariant(h.session.snapshot.value)
        XCTAssertEqual(h.titles(), ["Song 1", "Song 3", "Song 9", "Song 2", "Song 8", "Song 4"])
        XCTAssertEqual(h.session.snapshot.value.queue.filter { h.session.snapshot.value.queued.contains($0.id) }.map(\.title), ["Song 3", "Song 9"])
    }

    func testClearingTheQueuedGroupRemovesOnlyThoseSongsAndLeavesTheList() async {
        let h = harness()
        h.session.playList((1...3).map(track), start: 0, label: "Album")
        await h.step()
        h.session.add([track(8), track(9)], next: false)
        h.session.clearQueued()
        let s = h.session.snapshot.value
        checkInvariant(s)
        XCTAssertTrue(s.queued.isEmpty)
        XCTAssertEqual(s.label, "Album")
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 3"])
        XCTAssertEqual(h.player.queuedNext?.title, "Song 2")
    }

    func testAutoplaySongsStayInTheThirdTierBehindQueuedSongsAndTheList() async {
        let h = harness()
        h.session.playList((1...2).map(track), start: 1)
        await h.step()
        h.session.add([track(10), track(11)], next: false, queued: false, auto: true)
        h.session.add([track(8)], next: false)
        h.session.add([track(3)], next: false, queued: false)
        let s = h.session.snapshot.value
        checkInvariant(s)
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 8", "Song 3", "Song 10", "Song 11"])
        XCTAssertEqual(s.queue.filter(\.auto).map(\.title), ["Song 10", "Song 11"])
    }

    func testASongInTheListCanStillBeAddedToTheQueuedGroupButNotTwiceToTheQueuedGroup() async {
        let h = harness()
        h.session.playList((1...3).map(track), start: 0)
        await h.step()
        h.session.add([track(2)], next: false)
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 2", "Song 3"])
        h.session.add([track(2)], next: false)
        XCTAssertEqual(h.titles(), ["Song 1", "Song 2", "Song 2", "Song 3"])
    }

    func testSavedQueueRemembersTheQueuedGroupAndTheListLabelAndReadsOldFilesWithoutThem() async throws {
        let h = harness()
        h.session.playList((1...3).map(track), start: 0, label: "My List")
        await h.step()
        h.session.add([track(9)], next: false)
        let lastSaved = try XCTUnwrap(h.saved.last)
        XCTAssertEqual(lastSaved.label, "My List")
        XCTAssertEqual(lastSaved.queued.count, 1)

        let restored = harness(lastSaved)
        checkInvariant(restored.session.snapshot.value)
        XCTAssertEqual(restored.session.snapshot.value.label, "My List")
        XCTAssertEqual(restored.titles(), ["Song 1", "Song 9", "Song 2", "Song 3"])
        XCTAssertEqual(restored.session.snapshot.value.queue.filter { restored.session.snapshot.value.queued.contains($0.id) }.map(\.title), ["Song 9"])

        let oldJson = #"{"queue":[{"id":"q1","videoId":"aaaaaaaaaaa","title":"One","artist":"x","durMs":1000,"addedBy":"","auto":false}],"index":0,"repeat":"off","positionMs":0,"finished":false}"#
        let decoded = try JSONDecoder().decode(SavedQueue.self, from: Data(oldJson.utf8))
        XCTAssertTrue(decoded.queued.isEmpty)
        XCTAssertNil(decoded.label)
        XCTAssertFalse(decoded.queue[0].explicit)
        XCTAssertNil(decoded.queue[0].year)

        // Wire round-trip for explicit and year
        let addJson = Wire.queueAdd(TrackRef(videoId: "bNp9pn0ni3I", title: "Song", artist: "Artist", thumb: nil, durMs: 180_000, explicit: true, year: "2017"))
        XCTAssertTrue(addJson.contains("\"explicit\":true"))
        XCTAssertTrue(addJson.contains("\"year\":\"2017\""))
        if case let .prepare(_, _, item, _, _) = Wire.parse(#"{"t":"prepare","epoch":1,"index":0,"seekToMs":0,"item":{"id":"q1","videoId":"bNp9pn0ni3I","title":"Song","artist":"Artist","durMs":180000,"addedBy":"u1","explicit":true,"year":"2017"}}"#) {
            XCTAssertTrue(item.explicit)
            XCTAssertEqual(item.year, "2017")
        } else {
            XCTFail("Expected prepare message")
        }
    }

    private func randomTaps(transientOnly: Bool) async {
        for seed in 1...12 {
            let h = harness()
            var rng = SplitMix(seed: UInt64(seed))
            func roll(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
            var draw = SplitMix(seed: UInt64(seed) &+ 1000)
            h.player.failWith = { _ in
                guard Int(draw.next() % 10) < 4 else { return nil }
                switch transientOnly ? 0 : Int(draw.next() % 3) {
                case 0: return NSError(domain: "blip", code: 1)
                case 1: return LoadFailure(reason: .unplayable, message: "gone")
                default: return LoadFailure(reason: .offline, message: "no network")
                }
            }
            h.session.add((1...8).map(track), next: false)
            for _ in 0..<150 {
                let snapshot = h.session.snapshot.value
                let queue = snapshot.queue
                let pastTheEnd = snapshot.index + 1 >= queue.count && snapshot.repeatMode != "all"
                switch roll(19) {
                case 0, 1: if !pastTheEnd { h.session.next() }
                case 2: h.session.prev()
                case 3: h.session.pause()
                case 4, 5: h.session.play()
                case 6, 7: if !queue.isEmpty { h.session.jump(queue[roll(queue.count)].id) }
                case 8: h.session.setRepeat(["off", "all", "one"][roll(3)])
                case 9: h.session.add([track(9 + roll(30))], next: roll(2) == 0)
                case 10: if queue.count > 1, snapshot.index < queue.count - 1 { h.session.remove(queue[roll(queue.count)].id) }
                case 11: h.player.onError?(NSError(domain: "t", code: 403))
                case 12: h.player.prepareDelayMs = Int64(roll(9_000))
                case 13: h.session.seek(Int64(roll(100_000)))
                case 14: h.session.setShuffle(roll(2) == 0)
                case 15:
                    if snapshot.index + 1 < queue.count {
                        let span = queue.count - (snapshot.index + 1)
                        let from = snapshot.index + 1 + roll(span)
                        let to = snapshot.index + 1 + roll(span)
                        let qOpt: [Bool?] = [nil, true, false]
                        h.session.move(queue[from].id, toIndex: to, queued: qOpt[roll(3)])
                    }
                case 16:
                    if queue.dropFirst(snapshot.index + 1).contains(where: { !snapshot.queued.contains($0.id) }) {
                        h.session.clearQueued()
                    }
                case 17:
                    let count = 2 + roll(5)
                    h.session.playList((0..<count).map { _ in track(1 + roll(30)) }, start: roll(count), label: "L")
                default:
                    h.session.add([track(40 + roll(20))], next: false, queued: false, auto: roll(2) == 0)
                }
                checkInvariant(h.session.snapshot.value)
                await h.step(Int64(roll(5_000)))
                checkInvariant(h.session.snapshot.value)
                if transientOnly { XCTAssertTrue(h.ended.isEmpty, "seed \(seed): a blip ended the queue, which would start autoplay") }
            }
            // Nobody touches it any more, and the network is fine: it settles, with nothing still loading
            h.player.failWith = nil
            h.player.prepareDelayMs = 0
            await h.step(120_000)
            XCTAssertFalse(h.session.snapshot.value.loading, "seed \(seed): it is still loading")
        }
    }

    func testRandomTapsAmongRandomBlipsNeverEndTheQueueOrLeaveItLoadingForEver() async {
        await randomTaps(transientOnly: true)
    }

    func testRandomTapsAmongEveryKindOfFailureNeverLeaveItLoadingForEver() async {
        await randomTaps(transientOnly: false)
    }

    func testASongThatWillNotPlayOrTheLackOfANetworkIsNotTriedAgainAtOnce() async {
        let unplayable = harness()
        unplayable.player.failWith = { _ in LoadFailure(reason: .unplayable, message: "gone") }
        unplayable.session.add([track(1)], next: false)
        await unplayable.step(LocalSession.retryAfterMs + 500)
        XCTAssertEqual(unplayable.player.prepareAttempts, 1)

        let offline = harness()
        offline.player.failWith = { _ in LoadFailure(reason: .offline, message: "no network") }
        offline.session.add([track(1)], next: false)
        await offline.step(LocalSession.retryAfterMs + 500)
        XCTAssertEqual(offline.player.prepareAttempts, 1)
    }

    func testAStreamThatKeepsBreakingIsSkippedEvenWhileRepeatingThatSong() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step(1000)
        h.session.setRepeat("one")
        for _ in 0..<4 {
            h.player.onError?(URLError(.badServerResponse))
            await h.step()
        }
        XCTAssertEqual(h.player.loaded?.title, "Song 2", "repeating must not load the broken stream for ever")
    }

    func testTheQueueHoldsAThousandSongsAndThenSaysItIsFull() async {
        let h = harness()
        h.session.add((1...600).map(track), next: false)
        await h.step()
        h.session.add((601...1200).map(track), next: false)
        await h.step()
        XCTAssertEqual(h.session.snapshot.value.queue.count, 1000)
        h.session.add([track(1201)], next: false)
        XCTAssertTrue(h.problems.contains { $0.kind == .queueFull })
    }

    func testTheQueueSurvivesARoundTripThroughItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = QueueFile(url: url)
        let saved = SavedQueue(
            queue: [QueueItem(id: "a", videoId: "aaaaaaaaaaa", title: "One", artist: "x", thumb: "https://i/x.jpg", durMs: 1000, addedBy: "")],
            index: 0, repeatMode: "one", positionMs: 123, finished: true
        )
        file.write(saved)
        XCTAssertEqual(file.read(), saved)
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(file.read(), "a damaged file means an empty queue, not a crash")
    }

    // MARK: Connect: a queue handed to another device. The same cases are in LocalSessionTest.kt and web/local_session_test.dart

    func testAQueueHandedOverKeepsWhatMakesItTheSameQueue() async throws {
        let a = harness()
        a.session.playList((1...4).map(track), start: 1, label: "Album")
        a.session.add([track(5)], next: false)
        a.session.setShuffle(true)
        a.session.setRepeat("all")
        await a.step(5000)
        a.session.pause()
        let handed = a.session.exportQueue()
        XCTAssertEqual(handed.dropped, 0)
        // It travels as the JSON the queue file is
        let over = try JSONDecoder().decode(SavedQueue.self, from: JSONEncoder().encode(handed.saved))

        let b = harness()
        b.session.importQueue(over, play: true)
        await b.step()
        let before = a.session.snapshot.value
        let after = b.session.snapshot.value
        XCTAssertEqual(before.queue, after.queue)
        XCTAssertEqual(before.index, after.index)
        XCTAssertEqual(after.repeatMode, "all")
        XCTAssertTrue(after.shuffle)
        XCTAssertEqual(before.queued, after.queued)
        XCTAssertEqual(after.label, "Album")
        XCTAssertEqual(b.player.loaded?.title, before.current?.title)
        XCTAssertTrue(b.player.playing)
        XCTAssertTrue((4000...7000).contains(b.player.position), "went on where it stopped, was \(b.player.position)")
        // Shuffle off puts the songs back in the order they had, as it would have on the first device
        a.session.setShuffle(false)
        b.session.setShuffle(false)
        XCTAssertEqual(a.titles(), b.titles())
    }

    func testImportingAQueueStopsWhatPlayedAndWithoutPlayWaitsWhereItWas() async {
        let h = harness()
        h.session.add([track(1), track(2)], next: false)
        await h.step(3000)
        XCTAssertTrue(h.player.playing)
        h.session.importQueue(SavedQueue(queue: [item("z", "zzzzzzzzzzz", "Other")], positionMs: 42_000), play: false)
        await h.step()
        XCTAssertFalse(h.player.playing)
        XCTAssertEqual(h.titles(), ["Other"])
        XCTAssertEqual(h.session.restoredPositionMs, 42_000)
    }

    func testTheSongsOnlyThisDeviceHasAreLeftOutOfAHandOverAndTheIndexFollowsTheSong() {
        let one = item("a", "aaaaaaaaaaa", "One")
        let mine = item("b", "local:0123456789abcdef", "Mine")
        let three = item("c", "ccccccccccc", "Three")
        let four = item("d", "ddddddddddd", "Four")
        // On a song that goes with it
        let on = harness(SavedQueue(queue: [one, mine, three, four], index: 2, positionMs: 9_000, shuffleOrder: ["d", "b", "c", "a"], queued: ["c", "d"]))
        let kept = on.session.exportQueue()
        XCTAssertEqual(kept.dropped, 1)
        XCTAssertEqual(kept.saved.queue.map(\.title), ["One", "Three", "Four"])
        XCTAssertEqual(kept.saved.index, 1)
        XCTAssertEqual(kept.saved.positionMs, 9_000)
        XCTAssertEqual(kept.saved.queued, ["d"], "only what is still to come after the song counts as queued")
        XCTAssertEqual(kept.saved.shuffleOrder, ["d", "c", "a"])
        // On a song that stays behind: the next that goes, from its start
        let at = harness(SavedQueue(queue: [one, mine, three, four], index: 1, positionMs: 9_000))
        let next = at.session.exportQueue()
        XCTAssertEqual(next.saved.index, 1)
        XCTAssertEqual(next.saved.queue[next.saved.index].title, "Three")
        XCTAssertEqual(next.saved.positionMs, 0)
        // A queue of nothing but its own music hands over an empty one
        let only = harness(SavedQueue(queue: [mine]))
        XCTAssertEqual(only.session.exportQueue().saved, SavedQueue())
        XCTAssertEqual(only.session.exportQueue().dropped, 1)
    }
}

/// A random source that always gives the same numbers.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
