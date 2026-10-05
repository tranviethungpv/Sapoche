import XCTest
@testable import SapocheCore

@MainActor
final class GroupSessionTests: XCTestCase {
    private let item = QueueItem(id: "q1", videoId: "bNp9pn0ni3I", title: "Song", artist: "Artist", thumb: nil, durMs: 200_000, addedBy: "dev-a")
    private let item2 = QueueItem(id: "q2", videoId: "UoXllQoqEBY", title: "Song 2", artist: "Artist", thumb: nil, durMs: 180_000, addedBy: "dev-a")

    @MainActor
    private final class Harness {
        let time = VirtualTime()
        let clock = ClockSync()
        let player: FakePlayer
        var sent: [String] = []
        let scope = Scope()
        var session: GroupSession!

        init(serverOffsetMs: Int64) {
            // rtt 20ms, server clock reads local + serverOffsetMs
            clock.addSample(c0: 0, c2: 20, s1: serverOffsetMs + 10)
            player = FakePlayer(time: time)
            session = GroupSession(scope: scope, player: player, clock: clock, time: time, send: { [weak self] in self?.sent.append($0) })
        }

        func serverNow() -> Int64 { clock.toServer(time.now) }
        func step(_ ms: Int64) async { await time.advance(ms) }
        func run() async { await time.settle() }
        func sentAny(_ parts: String...) -> Bool { sent.contains { text in parts.allSatisfy { text.contains($0) } } }
        func message(_ message: ServerMessage) { session.onMessage(message) }
    }

    private var harnesses: [Harness] = []

    private func harness(offset: Int64 = 5000) -> Harness {
        let h = Harness(serverOffsetMs: offset)
        harnesses.append(h)
        return h
    }

    override func tearDown() async {
        harnesses.forEach { $0.scope.cancel() }
        harnesses = []
    }

    private func state(_ phase: String, epoch: Int64, startedAt: Int64 = 0, positionMs: Int64 = 0) -> ServerMessage {
        .state(serverNow: 0, you: "dev-a", state: RoomState(queue: [item], index: 0, phase: phase, startedAt: startedAt, positionMs: positionMs, epoch: epoch), members: [], protocolVersion: 0)
    }

    private func twoItemState(_ phase: String, epoch: Int64, index: Int = 0, startedAt: Int64 = 0) -> ServerMessage {
        .state(serverNow: 0, you: "dev-a", state: RoomState(queue: [item, item2], index: index, phase: phase, startedAt: startedAt, positionMs: 0, epoch: epoch), members: [], protocolVersion: 0)
    }

    private func prepare(_ epoch: Int64, _ item: QueueItem, seek: Int64 = 0, index: Int = 0, by: String? = nil) -> ServerMessage {
        .prepare(epoch: epoch, index: index, item: item, seekToMs: seek, by: by)
    }

    private func start(_ epoch: Int64, _ startAt: Int64, _ positionMs: Int64 = 0, by: String? = nil) -> ServerMessage {
        .start(epoch: epoch, startAt: startAt, positionMs: positionMs, by: by)
    }

    /// Room with two queued items, item 1 playing since server time 0 on epoch 1.
    private func playingFirstOfTwo() async -> Harness {
        let h = harness()
        h.message(twoItemState("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(1500)
        return h
    }

    func testReportsReadyAfterPreparingAndStartsExactlyAtTheScheduledServerTime() async {
        let h = harness(offset: 5000)
        h.message(prepare(1, item))
        await h.run()
        XCTAssertEqual(h.player.loaded, item)
        XCTAssertTrue(h.sentAny("\"ready\"", "\"epoch\":1"))

        h.message(start(1, h.serverNow() + 1500))
        await h.step(1499)
        XCTAssertFalse(h.player.playing, "must not start early")
        await h.step(1)
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.player.playedAtLocal, 1500)
    }

    func testTheSongSwappedForItsVideoIsLoadedAgainFromTheSameMomentAndTheRoomCarriesOn() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(4000)
        XCTAssertTrue(h.player.playing)

        var video = item
        video.videoId = "videoSwappd"
        video.durMs = 210_000
        h.message(prepare(2, video, seek: 2500))
        await h.run()
        XCTAssertEqual(h.player.loaded, video)
        XCTAssertTrue(h.sentAny("\"ready\"", "\"epoch\":2"))
        XCTAssertEqual(h.player.position, 2500)

        h.message(start(2, h.serverNow() + 1500, 2500))
        await h.step(1500)
        XCTAssertTrue(h.player.playing)
    }

    func testADeviceThatArrivesLateSkipsAheadInsteadOfStartingFromZero() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        await h.step(3000)
        // The start moment was 2000ms ago
        h.message(start(1, h.serverNow() - 2000))
        await h.run()
        XCTAssertTrue(h.player.playing)
        XCTAssertLessThanOrEqual(abs(h.player.position - 2150), 200, "expected about 2150ms, was \(h.player.position)")
    }

    func testASlowDeviceFinishesItsOwnPreparationBeforeStarting() async {
        let h = harness()
        h.player.prepareDelayMs = 3000
        h.message(prepare(1, item))
        await h.run()
        // The barrier timed out on the server and released the start while we are still loading
        h.message(start(1, h.serverNow() + 1500))
        await h.step(2000)
        XCTAssertFalse(h.player.playing, "still loading")
        await h.step(1500)
        XCTAssertTrue(h.player.playing)
        XCTAssertLessThan(abs(h.player.position - (h.time.now - 1500)), 400, "position \(h.player.position) vs \(h.time.now - 1500)")
    }

    func testSmallDriftIsCorrectedByNudgingSpeedAndSpeedReturnsToNormal() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(1500)
        await h.step(1000)
        h.player.nudge(+120) // this device is now 120ms ahead
        await h.step(5000)
        XCTAssertEqual(h.player.currentSpeed, 0.97, "ahead: must slow down")
        await h.step(12000)
        XCTAssertEqual(h.player.currentSpeed, 1, "back to normal once aligned")
        let drift = h.player.positionMs() - (h.time.now - 1500)
        XCTAssertLessThan(abs(drift), 50, "still off by \(drift)ms")
        XCTAssertLessThanOrEqual(h.player.seeks.count, 1, "no correction seeks expected, got \(h.player.seeks)")
    }

    func testADeviceThatIsBehindSpeedsUp() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(2500)
        h.player.nudge(-150)
        await h.step(5000)
        XCTAssertEqual(h.player.currentSpeed, 1.03)
    }

    func testLargeDriftIsCorrectedBySeeking() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(2500)
        let seeksBefore = h.player.seeks.count
        h.player.nudge(+1500)
        await h.step(2500)
        XCTAssertGreaterThan(h.player.seeks.count, seeksBefore, "expected a corrective seek")
        XCTAssertEqual(h.player.currentSpeed, 1)
        let expected = h.time.now - 1500
        XCTAssertLessThan(abs(h.player.positionMs() - expected), 250, "position \(h.player.positionMs()) vs \(expected)")
    }

    func testTheSnapshotFollowsStartAndPauseEvenThoughTheServerSendsNoStateForThem() async {
        let h = harness()
        h.message(state("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        XCTAssertEqual(h.session.snapshot.value.state?.phase, "preparing")

        let startAt = h.serverNow() + 1500
        h.message(start(1, startAt))
        await h.run()
        XCTAssertEqual(h.session.snapshot.value.state?.phase, "playing")
        XCTAssertEqual(h.session.snapshot.value.state?.startedAt, startAt)

        h.message(.pause(epoch: 2, positionMs: 2400, by: nil))
        await h.run()
        XCTAssertEqual(h.session.snapshot.value.state?.phase, "paused")
        XCTAssertEqual(h.session.snapshot.value.state?.positionMs, 2400)
    }

    func testItPlaysInStepFromTheMomentTheRoomStartsUntilTheRoomPauses() async {
        let h = harness()
        h.message(state("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        XCTAssertFalse(h.session.isInSync, "loaded, not started")

        h.message(start(1, h.serverNow() + 1500))
        await h.step(1600)
        XCTAssertTrue(h.session.isInSync)

        h.message(.pause(epoch: 2, positionMs: 2400, by: nil))
        await h.run()
        XCTAssertFalse(h.session.isInSync)
    }

    func testAPauseDuringTheBarrierHoldsTheLoadedSongAndTheStartAfterItPlaysIt() async {
        let h = harness()
        h.message(state("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        h.message(.pause(epoch: 2, positionMs: 0, by: "dev-b"))
        await h.step(3000)
        XCTAssertFalse(h.player.playing, "nothing starts behind the pause")
        XCTAssertEqual(h.session.snapshot.value.state?.phase, "paused")

        h.message(start(3, h.serverNow() + 1500))
        await h.step(1600)
        XCTAssertTrue(h.player.playing)
    }

    func testADeviceHeldFromOutsideLoadsWhatTheRoomDoesButStaysQuietUntilItsPersonPressesPlay() async {
        let h = harness()
        h.message(state("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        h.session.hold() // another app took the sound
        h.message(start(1, h.serverNow() + 1500))
        await h.step(1600)
        XCTAssertFalse(h.player.playing, "the room's start does not take the sound back")
        XCTAssertTrue(h.session.isInSync)
        XCTAssertTrue(h.session.isHeld)

        // The room plays on; the person comes back 20 seconds later and presses play
        await h.step(20_000)
        h.player.seeks.removeAll()
        h.session.resumeHere()
        await h.run()
        XCTAssertTrue(h.player.playing)
        XCTAssertFalse(h.session.isHeld)
        let landed = h.player.seeks.last ?? -1
        XCTAssertTrue((19_500...21_000).contains(landed), "it went to where the room is (\(landed) ms), not back to where the sound was lost")
    }

    func testASongTheRoomMovesToWhileTheDeviceIsHeldIsLoadedAndLeftPaused() async {
        let h = harness()
        h.message(twoItemState("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(2000)
        XCTAssertTrue(h.player.playing)
        h.session.hold()
        h.player.pause()

        h.message(twoItemState("preparing", epoch: 2, index: 1))
        h.message(prepare(2, item2, index: 1))
        await h.run()
        h.message(start(2, h.serverNow() + 1500))
        await h.step(2000)
        XCTAssertEqual(h.player.loaded?.title, "Song 2")
        XCTAssertFalse(h.player.playing, "someone else's skip does not start the sound here")
    }

    func testPauseStopsPlaybackAtTheGivenPosition() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(4000)
        h.message(.pause(epoch: 2, positionMs: 2400, by: nil))
        await h.run()
        XCTAssertFalse(h.player.playing)
        XCTAssertEqual(h.player.position, 2400)
        await h.step(5000)
        XCTAssertEqual(h.player.position, 2400, "stays put while paused")
    }

    func testClosingTheSessionSilencesThePlayerAtOnce() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 100))
        await h.step(2000)
        XCTAssertTrue(h.player.playing)

        h.session.close() // no settling: whoever leaves cancels the scope right away
        XCTAssertFalse(h.player.playing)
        XCTAssertNil(h.player.loaded)
    }

    func testMessagesFromAnOlderEpochAreIgnored() async {
        let h = harness()
        h.message(prepare(5, item))
        await h.run()
        h.message(start(3, h.serverNow() + 100))
        await h.step(1000)
        XCTAssertFalse(h.player.playing)
    }

    func testAFailedPreparationIsReportedInsteadOfBlockingTheRoom() async {
        let h = harness()
        h.player.failPrepare = true
        h.message(prepare(1, item))
        await h.run()
        XCTAssertTrue(h.sentAny("resolveFailed", "\"epoch\":1"))
        XCTAssertFalse(h.sentAny("\"ready\""))
    }

    func testJoiningARoomThatIsAlreadyPlayingLandsOnTheCurrentPosition() async {
        let h = harness()
        await h.step(1000)
        // Position 0 was played 10 seconds ago
        let startedAt = h.serverNow() - 10_000
        h.message(state("playing", epoch: 4, startedAt: startedAt))
        await h.step(2000)
        XCTAssertTrue(h.player.playing)
        await h.step(1000)
        let expected = h.serverNow() - startedAt
        XCTAssertLessThan(abs(h.player.positionMs() - expected), 300, "position \(h.player.positionMs()) vs expected \(expected)")
    }

    func testReconnectingIntoTheSameEpochDoesNotDisturbPlayback() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(3000)
        let seeksBefore = h.player.seeks.count
        // After a reconnect the server sends the current state again, with the same epoch
        h.message(state("playing", epoch: 1, startedAt: h.serverNow() - 1500))
        await h.step(1000)
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.player.seeks.count, seeksBefore)
    }

    func testReportsTheEndOfAnItemOnce() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(2000)
        XCTAssertNotNil(h.player.onEnded)
        h.player.onEnded?()
        await h.run()
        XCTAssertEqual(h.sent.filter { $0.contains("\"ended\"") && $0.contains("\"epoch\":1") }.count, 1)
    }

    func testAStreamThatBreaksMidTrackIsReloadedAndRejoinsTheRoomPosition() async {
        let h = harness()
        // The session needs the room state to know which item is playing
        h.message(state("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        let startAt = h.serverNow() + 1500
        h.message(start(1, startAt))
        await h.step(6000)
        XCTAssertTrue(h.player.playing)

        // Simulate the player dying and losing its item, like an AVPlayer error does
        h.player.playing = false
        h.player.loaded = nil
        h.player.onError?(NSError(domain: "t", code: 403))
        await h.step(3000)

        XCTAssertEqual(h.player.loaded, item, "reloaded")
        XCTAssertTrue(h.player.playing, "playing again")
        let expected = h.serverNow() - startAt
        XCTAssertLessThan(abs(h.player.positionMs() - expected), 400, "position \(h.player.positionMs()) vs \(expected)")
    }

    func testAStreamThatKeepsFailingIsAbandonedAfterAFewRecoveries() async {
        let h = harness()
        h.message(state("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(3000)
        var recoveredLoads = 0
        for _ in 0..<10 {
            h.player.playing = false
            h.player.loaded = nil
            h.player.onError?(NSError(domain: "t", code: 403))
            await h.step(2500)
            if h.player.loaded != nil { recoveredLoads += 1 }
        }
        XCTAssertEqual(recoveredLoads, 5, "exactly the allowed number of recoveries")
    }

    func testANewPrepareInterruptsPlaying() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(3000)
        XCTAssertTrue(h.player.playing)
        var other = item
        other.id = "q2"
        h.message(prepare(2, other))
        await h.run()
        XCTAssertFalse(h.player.playing)
        XCTAssertTrue(h.sentAny("\"ready\"", "\"epoch\":2"))
    }

    // ------------------------------------------------------------------ gapless advance

    func testTheNextItemIsHandedToThePlayerWhileFollowingTheRoom() async {
        let h = await playingFirstOfTwo()
        XCTAssertEqual(h.player.queuedNext, item2)
    }

    func testNoSuccessorIsQueuedWhileRepeatingOneItem() async {
        let h = harness()
        let two = { (repeatMode: String) -> ServerMessage in
            .state(serverNow: 0, you: "dev-a",
                   state: RoomState(queue: [self.item, self.item2], index: 0, phase: "playing", startedAt: h.serverNow() - 5000, positionMs: 0, epoch: 1, repeatMode: repeatMode),
                   members: [], protocolVersion: 0)
        }
        h.message(two("off"))
        await h.run()
        await h.step(3000)
        XCTAssertEqual(h.player.queuedNext, item2, "the successor is preloaded as usual")

        h.message(two("one"))
        await h.run()
        XCTAssertNil(h.player.queuedNext, "repeating one item must not slip into the next one")

        h.message(two("all"))
        await h.run()
        XCTAssertEqual(h.player.queuedNext, item2)
    }

    func testNoSuccessorIsQueuedAfterTheLastItem() async {
        let h = harness()
        h.message(state("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(1500)
        XCTAssertNil(h.player.queuedNext)
    }

    func testATrackAddedLaterBecomesTheSuccessor() async {
        let h = harness()
        h.message(state("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(1500)
        h.message(twoItemState("playing", epoch: 1, startedAt: h.serverNow() - 1500))
        await h.run()
        XCTAssertEqual(h.player.queuedNext, item2)
    }

    func testMovingOnByItselfIsReportedOnceThePositionHasSettled() async {
        let h = await playingFirstOfTwo()
        await h.step(5000)
        h.player.autoAdvance()
        await h.step(900)
        XCTAssertTrue(h.sent.allSatisfy { !$0.contains("\"advanced\"") }, "must wait before reporting")
        await h.step(200)
        let reports = h.sent.filter { $0.contains("\"advanced\"") }
        XCTAssertEqual(reports.count, 1)
        let report = reports[0]
        XCTAssertTrue(report.contains("\"itemId\":\"q2\"") && report.contains("\"epoch\":1"), report)
        let digits = report.components(separatedBy: "\"startedAt\":")[1].prefix { $0.isNumber || $0 == "-" }
        let startedAt = Int64(digits)!
        // Position 0 was heard about 1100ms ago
        XCTAssertLessThan(abs(startedAt - (h.serverNow() - 1100)), 60, "startedAt=\(startedAt) now=\(h.serverNow())")
    }

    func testTheRoomsAdvanceIsAdoptedAndDriftCorrectionCarriesOn() async {
        let h = await playingFirstOfTwo()
        await h.step(5000)
        h.player.autoAdvance()
        await h.step(1100)
        h.message(.advance(epoch: 2, index: 1, startedAt: h.serverNow() - 1100))
        await h.step(6000)
        XCTAssertEqual(h.player.loaded, item2)
        XCTAssertEqual(h.player.prepareCount, 1, "no reload for a device that advanced by itself")
        XCTAssertEqual(h.player.currentSpeed, 1)
        XCTAssertLessThanOrEqual(h.player.seeks.count, 1, "no corrective seeks expected: \(h.player.seeks)")
        XCTAssertEqual(h.session.snapshot.value.state?.index, 1)
    }

    func testAnAdvanceThatArrivesBeforeTheLocalPlayerAdvancesWaitsForIt() async {
        let h = await playingFirstOfTwo()
        await h.step(5000)
        // The room already knows: item 2 starts 100ms from now
        h.message(.advance(epoch: 2, index: 1, startedAt: h.serverNow() + 100))
        await h.step(100)
        h.player.autoAdvance()
        await h.step(6000)
        XCTAssertTrue(h.sent.allSatisfy { !$0.contains("\"advanced\"") }, "nothing to report, the room already knew")
        XCTAssertEqual(h.player.prepareCount, 1)
        XCTAssertEqual(h.player.currentSpeed, 1)
        XCTAssertLessThanOrEqual(h.player.seeks.count, 1, "no corrective seeks expected: \(h.player.seeks)")
    }

    func testAPlayerThatNeverAdvancesIsReloadedAtTheRoomsPosition() async {
        let h = await playingFirstOfTwo()
        await h.step(5000)
        h.message(.advance(epoch: 2, index: 1, startedAt: h.serverNow() - 500))
        await h.step(6000)
        XCTAssertEqual(h.player.loaded, item2)
        XCTAssertEqual(h.player.prepareCount, 2)
        XCTAssertTrue(h.player.playing)
    }

    func testAStaleAdvanceIsIgnored() async {
        let h = await playingFirstOfTwo()
        await h.step(1000)
        h.message(.advance(epoch: 1, index: 1, startedAt: h.serverNow()))
        await h.step(6000)
        XCTAssertEqual(h.player.loaded, item)
    }

    // ------------------------------------------------------------------ resilience

    func testReconnectingToARoomThatIsOnTheSameItemDoesNotReloadIt() async {
        let h = await playingFirstOfTwo()
        await h.step(4000)
        let startedAt = h.serverNow() - 4000
        h.message(twoItemState("playing", epoch: 2, startedAt: startedAt))
        await h.step(3000)
        XCTAssertEqual(h.player.prepareCount, 1, "the item must stay loaded")
        XCTAssertTrue(h.player.playing)
    }

    func testReconnectingAfterBeingPausedLocallyResumesPlayback() async {
        let h = await playingFirstOfTwo()
        await h.step(4000)
        h.player.pause() // e.g. audio focus lost during the outage
        await h.step(2000)
        let startedAt = h.serverNow() - 6000
        h.message(twoItemState("playing", epoch: 2, startedAt: startedAt))
        await h.step(1000)
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.player.prepareCount, 1)
        let expected = h.time.now - 1500
        XCTAssertLessThan(abs(h.player.position - expected), 400, "position \(h.player.position) vs \(expected)")
    }

    func testARepeatedPrepareForAnItemThatIsAlreadyLoadedOnlyReportsReadyAgain() async {
        let h = harness()
        h.message(prepare(1, item))
        await h.run()
        h.sent.removeAll()
        h.message(prepare(1, item))
        await h.run()
        XCTAssertEqual(h.player.prepareCount, 1)
        XCTAssertTrue(h.sentAny("\"ready\""))
    }

    func testStartLatencyIsLearnedAndTheNextStartLandsOnTime() async {
        let h = harness()
        h.player.startLatencyMs = 300
        h.message(twoItemState("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        h.message(start(1, h.serverNow() + 1500))
        await h.step(1500 + 6000)
        XCTAssertLessThanOrEqual(abs(h.session.startBiasMs - 240), 80, "learned \(h.session.startBiasMs)")

        // The next start aims ahead by the learned bias, so the first readings are already close
        h.message(prepare(2, item))
        await h.run()
        h.message(start(2, h.serverNow() + 1500))
        await h.step(1500 + 1000)
        // Position 0 was due 1000ms ago
        let drift = h.player.positionMs() - 1000
        XCTAssertLessThan(abs(drift), 100, "drift \(drift), expected around 0 (bias \(h.session.startBiasMs))")
    }

    func testAFailedCatchUpLoadIsRetriedUntilTheNetworkIsBack() async {
        let h = harness()
        h.player.failPrepare = true
        h.message(twoItemState("playing", epoch: 1, startedAt: h.serverNow() - 10_000))
        await h.step(12_000)
        XCTAssertFalse(h.player.playing, "still offline")
        h.player.failPrepare = false
        await h.step(6000)
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.player.loaded, item)
        // The room started 10s before t=0, so its position is the local time plus 10s
        let roomPosition = h.time.now + 10_000
        XCTAssertLessThan(abs(h.player.position - roomPosition), 600, "position \(h.player.position) vs \(roomPosition)")
    }

    func testRecoveriesAreForgottenAfterALongHealthyStretch() async {
        let h = await playingFirstOfTwo()
        await h.step(2000)
        for _ in 0..<4 {
            h.player.onError?(NSError(domain: "t", code: 1))
            await h.step(4000)
        }
        await h.step(40_000) // healthy for a while
        for _ in 0..<4 {
            h.player.onError?(NSError(domain: "t", code: 1))
            await h.step(4000)
        }
        XCTAssertTrue(h.player.playing, "would have given up if the count was never reset")
    }

    func testADeviceTrimShiftsWhereTheDeviceAims() async {
        let h = await playingFirstOfTwo()
        h.session.trimMs = 100 // this device is heard 100ms late, so it must run 100ms ahead
        await h.step(5000)
        XCTAssertEqual(h.player.currentSpeed, 1.03, "an exactly aligned player is 100ms behind its target")
    }

    // ---- listening alone ----

    func testGoingSoloKeepsTheSongPlayingAndTellsTheRoom() async {
        let h = await playingFirstOfTwo()
        await h.step(2000)
        h.session.goSolo()
        await h.step(1000)
        XCTAssertTrue(h.player.playing, "going solo must not interrupt what is playing")
        XCTAssertTrue(h.sentAny("\"solo\"", "true"))
        XCTAssertTrue(h.session.snapshot.value.solo)
        XCTAssertEqual(h.session.snapshot.value.soloItemId, "q1")
    }

    func testWhileAloneTheRoomPausingDoesNotPauseThisDevice() async {
        let h = await playingFirstOfTwo()
        h.session.goSolo()
        await h.step(500)
        h.message(.pause(epoch: 2, positionMs: 5000, by: "dev-b"))
        await h.step(1000)
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.session.snapshot.value.state?.phase, "paused", "the view still shows what the room did")
    }

    func testWhileAloneTheRoomSkippingDoesNotMoveThisDeviceOrHoldTheRoomBack() async {
        let h = await playingFirstOfTwo()
        h.session.goSolo()
        await h.step(500)
        h.sent.removeAll()
        h.message(prepare(2, item2, index: 1, by: "dev-b"))
        await h.step(1000)
        XCTAssertEqual(h.player.loaded, item)
        XCTAssertTrue(h.player.playing)
        XCTAssertFalse(h.sentAny("\"ready\""), "a solo device does not answer the barrier")
    }

    func testAloneNextMovesAlongTheQueueOnThisDeviceOnly() async {
        let h = await playingFirstOfTwo()
        h.session.goSolo()
        await h.step(500)
        h.sent.removeAll()
        h.session.soloNext()
        await h.step(500)
        XCTAssertEqual(h.player.loaded, item2)
        XCTAssertTrue(h.player.playing)
        XCTAssertEqual(h.session.snapshot.value.soloItemId, "q2")
        XCTAssertFalse(h.sentAny("\"next\""))
    }

    func testAlonePausingPausesOnlyThisDevice() async {
        let h = await playingFirstOfTwo()
        h.session.goSolo()
        await h.step(500)
        h.sent.removeAll()
        h.session.soloPause()
        await h.step(100)
        XCTAssertFalse(h.player.playing)
        XCTAssertTrue(h.sent.isEmpty, "nothing is sent to the room")
        h.session.soloPlay()
        await h.step(100)
        XCTAssertTrue(h.player.playing)
    }

    func testAloneASongEndingMovesOnByItselfAndReportsNothing() async {
        let h = await playingFirstOfTwo()
        h.session.goSolo()
        await h.step(500)
        XCTAssertEqual(h.player.queuedNext, item2, "the next song is preloaded for a gapless finish")
        h.sent.removeAll()
        h.player.autoAdvance()
        await h.step(500)
        XCTAssertEqual(h.session.snapshot.value.soloItemId, "q2")
        XCTAssertTrue(h.sent.allSatisfy { !$0.contains("\"advanced\"") && !$0.contains("\"ended\"") })
    }

    func testAloneTheLastSongEndingStopsInsteadOfLooping() async {
        let h = await playingFirstOfTwo()
        h.session.goSolo()
        await h.step(500)
        h.session.soloNext()
        await h.step(500)
        h.player.onEnded?()
        await h.step(500)
        XCTAssertFalse(h.player.playing)
    }

    func testAfterARestartListeningAloneComesBackPausedOnTheSongItWasOn() async {
        let h = harness()
        h.session.restoreSolo(itemId: "q2")
        h.message(.state(serverNow: 0, you: "dev-a",
                         state: RoomState(queue: [item, item2], index: 0, phase: "playing", startedAt: 0, positionMs: 0, epoch: 3),
                         members: [], protocolVersion: 0))
        await h.step(500)
        XCTAssertTrue(h.session.snapshot.value.solo)
        XCTAssertEqual(h.session.snapshot.value.soloItemId, "q2")
        XCTAssertNil(h.player.loaded, "the room's song is not started for someone who listens alone")
        XCTAssertFalse(h.player.playing)

        h.session.onReconnected()
        await h.step(100)
        XCTAssertTrue(h.sentAny("\"solo\"", "true"), "the room is told this device is alone")

        h.session.soloPlay()
        await h.step(500)
        XCTAssertEqual(h.player.loaded, item2, "play starts the song this device was on, not the room's")
        XCTAssertTrue(h.player.playing)
    }

    func testRejoiningAsksTheRoomForItsStateAndFollowsIt() async {
        let h = await playingFirstOfTwo()
        h.session.goSolo()
        await h.step(500)
        h.session.soloNext() // now on item 2 while the room is still on item 1
        await h.step(500)
        h.sent.removeAll()
        h.session.rejoin()
        await h.step(100)
        XCTAssertTrue(h.sentAny("\"solo\"", "false"))
        XCTAssertTrue(h.sentAny("\"resync\""))
        XCTAssertFalse(h.session.snapshot.value.solo)

        // The room answers with its state: item 1 has been playing for a while
        h.message(twoItemState("playing", epoch: 1, startedAt: h.serverNow() - 4000))
        await h.step(3000)
        XCTAssertEqual(h.player.loaded, item, "back on the room's song")
        XCTAssertTrue(h.player.playing)
    }

    func testTheRoomPausingWhileFollowingIsReportedButNotWhenThisDeviceDidIt() async {
        let h = await playingFirstOfTwo()
        var seen: [GroupSession.RoomEvent] = []
        let subscription = h.session.events.observe { seen.append($0) }
        defer { subscription.cancel() }
        h.message(.pause(epoch: 2, positionMs: 3000, by: "dev-b"))
        await h.step(100)
        XCTAssertEqual(seen, [.paused(byId: "dev-b")])

        h.message(start(3, h.serverNow() + 1500, 3000, by: "dev-b"))
        await h.step(1600)
        h.message(.pause(epoch: 4, positionMs: 5000, by: "dev-a"))
        await h.step(100)
        XCTAssertEqual(seen.count, 1, "our own pause is not news")
    }

    func testASkipBySomeoneElseIsReportedWithTheNewTitle() async {
        let h = await playingFirstOfTwo()
        var seen: [GroupSession.RoomEvent] = []
        let subscription = h.session.events.observe { seen.append($0) }
        defer { subscription.cancel() }
        h.message(prepare(2, item2, index: 1, by: "dev-b"))
        await h.step(100)
        XCTAssertEqual(seen, [.skipped(byId: "dev-b", title: "Song 2")])
    }

    func testThisDeviceFailingToLoadTheRoomsSongIsToldOnceHoweverOftenItRetries() async {
        let h = harness()
        var seen: [GroupSession.RoomEvent] = []
        let subscription = h.session.events.observe { seen.append($0) }
        defer { subscription.cancel() }
        h.player.failWith = { _ in LoadFailure(reason: .offline, message: "no network") }
        h.message(twoItemState("playing", epoch: 1, startedAt: h.serverNow() - 10_000))
        await h.step(30_000) // the catch-up load is tried every few seconds
        XCTAssertEqual(seen, [.loadFailed(title: "Song", reason: .offline)])
    }

    func testAFailedPreparationIsToldToThePersonToo() async {
        let h = harness()
        var seen: [GroupSession.RoomEvent] = []
        let subscription = h.session.events.observe { seen.append($0) }
        defer { subscription.cancel() }
        h.player.failPrepare = true
        h.message(prepare(1, item))
        await h.run()
        XCTAssertEqual(seen, [.loadFailed(title: "Song", reason: nil)])
    }

    func testPlayAfterGivingUpOnABrokenStreamLoadsTheRoomsSongAgain() async {
        let h = harness()
        var seen: [GroupSession.RoomEvent] = []
        let subscription = h.session.events.observe { seen.append($0) }
        defer { subscription.cancel() }
        h.message(state("preparing", epoch: 1))
        h.message(prepare(1, item))
        await h.run()
        let startAt = h.serverNow() + 1500
        h.message(start(1, startAt))
        await h.step(3000)
        for _ in 0..<6 {
            h.player.playing = false
            h.player.loaded = nil
            h.player.onError?(NSError(domain: "t", code: 403))
            await h.step(2500)
        }
        XCTAssertFalse(h.player.playing, "given up")
        XCTAssertEqual(seen.filter { if case .loadFailed = $0 { return true } else { return false } }.count, 1, "the person is told it stopped")

        XCTAssertTrue(h.session.catchUp())
        await h.step(3000)
        XCTAssertEqual(h.player.refreshed, [item.videoId], "trying again by hand asks for a new address")
        XCTAssertEqual(h.player.loaded, item)
        XCTAssertTrue(h.player.playing)
        let expected = h.serverNow() - startAt
        XCTAssertLessThan(abs(h.player.positionMs() - expected), 400, "position \(h.player.positionMs()) vs \(expected)")
        XCTAssertFalse(h.session.catchUp(), "with the song there, play only resumes it")
    }

    func testAlonePausingWhileASongLoadsLeavesItPausedWhenItIsThere() async {
        let h = await playingFirstOfTwo()
        h.session.goSolo()
        await h.step(500)
        h.player.prepareDelayMs = 3000
        h.session.soloNext()
        await h.step(500)
        XCTAssertTrue(h.session.snapshot.value.loading)
        h.session.soloPause()
        await h.step(500)
        XCTAssertFalse(h.session.snapshot.value.loading)
        await h.step(3000)
        XCTAssertEqual(h.player.loaded, item2)
        XCTAssertFalse(h.player.playing, "pause was pressed while it loaded")
    }

    func testAfterAReconnectTheRoomIsToldAgainThatThisDeviceIsAlone() async {
        let h = await playingFirstOfTwo()
        h.session.goSolo()
        await h.step(500)
        h.sent.removeAll()
        h.session.onReconnected()
        await h.step(100)
        XCTAssertTrue(h.sentAny("\"solo\"", "true"))
    }
}
