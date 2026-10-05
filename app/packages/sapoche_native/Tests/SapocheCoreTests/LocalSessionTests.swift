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
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        h.session.add([track(1), track(2), track(3), track(3)], next: false)
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
        XCTAssertTrue(h.problems.contains { $0.title == "Song 1" })
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
        await h.step()
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
        await h.step()
        XCTAssertEqual(h.problems.map(\.kind), [.failed])
        h.player.failPrepare = false
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

    func testAnyOtherFailureToLoadSaysSoWithWhatWentWrong() async {
        let h = harness()
        h.player.failPrepare = true
        h.session.add([track(1), track(2)], next: false)
        await h.step()
        XCTAssertEqual(h.problems.map(\.kind), [.failed])
        XCTAssertTrue(h.problems.first?.detail.contains("cannot load") == true, "was \(h.problems)")
        XCTAssertEqual(h.session.snapshot.value.current?.title, "Song 1")
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

    func testTheQueueIsCappedLikeTheRooms() async {
        let h = harness()
        h.session.add((1...150).map(track), next: false)
        await h.step()
        h.session.add((151...300).map(track), next: false)
        await h.step()
        XCTAssertEqual(h.session.snapshot.value.queue.count, 200)
        h.session.add([track(301)], next: false)
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
