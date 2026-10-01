import XCTest
@testable import UnisonCore

final class ListenTrackerTests: XCTestCase {
    private var heard: [(String, Int64)] = []
    private var tracker: ListenTracker!

    override func setUp() {
        heard = []
        tracker = ListenTracker { [unowned self] id, duration in self.heard.append((id, duration)) }
    }

    func testASongCountsAfterThirtySecondsOfPlaying() {
        tracker.begin(songId: "a", durationMs: 200_000, now: 0)
        tracker.setPlaying(true, now: 0)
        tracker.check(29_999)
        XCTAssertTrue(heard.isEmpty)
        tracker.check(30_000)
        XCTAssertEqual(heard.map(\.0), ["a"])
        XCTAssertEqual(heard.map(\.1), [200_000])
    }

    func testItCountsOnceHoweverOftenItIsChecked() {
        tracker.begin(songId: "a", durationMs: 200_000, now: 0)
        tracker.setPlaying(true, now: 0)
        tracker.check(31_000)
        tracker.check(90_000)
        tracker.begin(songId: nil, durationMs: 0, now: 100_000)
        XCTAssertEqual(heard.count, 1)
    }

    func testPausesAndBufferingDoNotCount() {
        tracker.begin(songId: "a", durationMs: 200_000, now: 0)
        tracker.setPlaying(true, now: 0)
        tracker.setPlaying(false, now: 20_000)
        tracker.check(500_000) // a long pause
        XCTAssertTrue(heard.isEmpty)
        tracker.setPlaying(true, now: 500_000)
        tracker.check(509_999)
        XCTAssertTrue(heard.isEmpty)
        tracker.check(510_000)
        XCTAssertEqual(heard.count, 1)
    }

    func testASongSkippedEarlyDoesNotCount() {
        tracker.begin(songId: "a", durationMs: 200_000, now: 0)
        tracker.setPlaying(true, now: 0)
        tracker.begin(songId: "b", durationMs: 180_000, now: 12_000)
        tracker.setPlaying(true, now: 12_000)
        tracker.begin(songId: nil, durationMs: 0, now: 20_000)
        XCTAssertTrue(heard.isEmpty)
    }

    func testASongThatHadJustPassedTheMarkWhenItWasSkippedStillCounts() {
        // The timer for it may not have run yet when the next song was already loading
        tracker.begin(songId: "a", durationMs: 200_000, now: 0)
        tracker.setPlaying(true, now: 0)
        tracker.begin(songId: "b", durationMs: 180_000, now: 30_500)
        XCTAssertEqual(heard.map(\.0), ["a"])
    }

    func testAShortSongCountsAtHalfItsLength() {
        tracker.begin(songId: "clip", durationMs: 20_000, now: 0)
        tracker.setPlaying(true, now: 0)
        tracker.check(9_999)
        XCTAssertTrue(heard.isEmpty)
        tracker.check(10_000)
        XCTAssertEqual(heard.map(\.0), ["clip"])
    }

    func testTheLengthMayBecomeKnownAfterTheSongBegan() {
        tracker.begin(songId: "a", durationMs: 0, now: 0)
        tracker.setPlaying(true, now: 0)
        XCTAssertEqual(tracker.msUntilHeard(0), 30_000)
        tracker.setDuration(40_000)
        XCTAssertEqual(tracker.msUntilHeard(0), 20_000)
        tracker.check(20_000)
        XCTAssertEqual(heard.map(\.1), [40_000])
    }

    func testItSaysHowLongToWaitAndNothingWhenThereIsNothingToWaitFor() {
        XCTAssertNil(tracker.msUntilHeard(0))
        tracker.begin(songId: "a", durationMs: 200_000, now: 0)
        XCTAssertNil(tracker.msUntilHeard(0), "not playing yet")
        tracker.setPlaying(true, now: 1_000)
        XCTAssertEqual(tracker.msUntilHeard(1_000), 30_000)
        XCTAssertEqual(tracker.msUntilHeard(11_000), 20_000)
        tracker.setPlaying(false, now: 11_000)
        XCTAssertNil(tracker.msUntilHeard(11_000))
        tracker.setPlaying(true, now: 50_000)
        XCTAssertEqual(tracker.msUntilHeard(50_000), 20_000, "the ten seconds already heard are kept")
        tracker.check(70_000)
        XCTAssertNil(tracker.msUntilHeard(70_000), "already counted")
    }

    func testPlayingWithNothingLoadedIsIgnored() {
        tracker.setPlaying(true, now: 0)
        tracker.check(60_000)
        XCTAssertTrue(heard.isEmpty)
    }

    func testTheSameSongAgainIsANewListen() {
        tracker.begin(songId: "a", durationMs: 200_000, now: 0)
        tracker.setPlaying(true, now: 0)
        tracker.check(30_000)
        tracker.begin(songId: "a", durationMs: 200_000, now: 200_000)
        tracker.setPlaying(true, now: 200_000)
        tracker.check(230_000)
        XCTAssertEqual(heard.count, 2)
    }
}

@MainActor
final class SleepTimerTests: XCTestCase {
    private let time = VirtualTime()
    private let scope = Scope()
    private var calls: [String] = []
    private var volumes: [Float] = []
    private var atSongEnd = false
    private var timer: SleepTimer!

    override func setUp() async throws {
        timer = SleepTimer(
            scope: scope, time: time,
            wallClock: { [time] in 1_000_000 + time.now },
            stop: { [unowned self] in self.calls.append("stop") },
            fade: { [unowned self] in self.volumes.append($0) },
            pauseAtSongEnd: { [unowned self] in self.atSongEnd = $0 }
        )
    }

    override func tearDown() async throws {
        scope.cancel()
    }

    func testItStopsWhenTheTimeIsUpAndNotBefore() async {
        timer.startIn(minutes: 10)
        XCTAssertEqual(timer.state.value, .at(endsAtMs: 1_000_000 + 600_000))
        await time.advance(599_999)
        XCTAssertEqual(calls, [])
        await time.advance(1)
        XCTAssertEqual(calls, ["stop"])
        XCTAssertEqual(timer.state.value, .off)
    }

    func testTheVolumeGoesDownOverTheLastSecondsAndComesBackAfterTheStop() async {
        timer.startIn(minutes: 1)
        volumes.removeAll()
        await time.advance(44_000)
        XCTAssertEqual(volumes, []) // full volume until the fade starts
        await time.advance(1_000) // the fade starts at 45 s
        XCTAssertEqual(volumes.first, 1)
        await time.advance(15_000)
        XCTAssertEqual(calls, ["stop"])
        XCTAssertTrue(zip(volumes.dropLast(), volumes.dropLast().dropFirst()).allSatisfy { $1 <= $0 }, "\(volumes)")
        XCTAssertEqual(volumes.last, 1)
        XCTAssertLessThan(volumes.min() ?? 1, 0.1)
    }

    func testCancellingStopsNothingAndGivesTheVolumeBack() async {
        timer.startIn(minutes: 5)
        await time.advance(290_000) // in the fade
        timer.cancel()
        volumes.removeAll()
        await time.advance(600_000)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(timer.state.value, .off)
        XCTAssertEqual(volumes, [])
    }

    func testANewSettingReplacesTheOldOne() async {
        timer.startIn(minutes: 5)
        await time.advance(240_000)
        timer.startIn(minutes: 30)
        await time.advance(600_000)
        XCTAssertEqual(calls, [])
        await time.advance(1_200_000)
        XCTAssertEqual(calls, ["stop"])
    }

    func testAtTheEndOfTheSongItAsksThePlayerToPauseThereAndStopsWhenToldItDid() async {
        timer.startAtSongEnd()
        XCTAssertTrue(atSongEnd)
        XCTAssertEqual(timer.state.value, .songEnd)
        await time.advance(3_600_000) // time does not matter
        XCTAssertEqual(calls, [])
        timer.songEnded()
        XCTAssertEqual(calls, ["stop"])
        XCTAssertEqual(timer.state.value, .off)
        XCTAssertFalse(atSongEnd)
    }

    func testASongEndingMeansNothingToATimerSetInMinutes() {
        timer.startIn(minutes: 10)
        timer.songEnded()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(timer.state.value, .at(endsAtMs: 1_000_000 + 600_000))
    }

    func testTurningItOffAfterChoosingTheSongEndLetsThePlayerCarryOn() {
        timer.startAtSongEnd()
        timer.cancel()
        XCTAssertFalse(atSongEnd)
        timer.songEnded()
        XCTAssertEqual(calls, [])
    }
}

@MainActor
final class IdleWatchTests: XCTestCase {
    private let time = VirtualTime()
    private let scope = Scope()
    private var actions: [IdleAction] = []
    private var watch: IdleWatch!
    private let room: Int64 = 20 * 60_000
    private let service: Int64 = 15 * 60_000

    override func setUp() async throws {
        watch = IdleWatch(scope: scope, time: time, roomAfterMs: room, serviceAfterMs: service) { [unowned self] in self.actions.append($0) }
        await time.settle()
    }

    override func tearDown() async throws {
        scope.cancel()
    }

    private func minutes(_ n: Int64) async { await time.advance(n * 60_000) }

    func testOutsideARoomTheServiceStopsAfterFifteenQuietMinutes() async {
        await minutes(14)
        XCTAssertEqual(actions, [])
        await minutes(2)
        XCTAssertEqual(actions, [.stopService])
    }

    func testInARoomTheConnectionIsLetGoOfAfterTwentyQuietMinutesNotTheService() async {
        watch.update(inRoom: true)
        await minutes(19)
        XCTAssertEqual(actions, [])
        await minutes(2)
        XCTAssertEqual(actions, [.suspendRoom])
    }

    func testNothingHappensWhileMusicPlaysOrTheScreenIsBeingLookedAt() async {
        watch.update(playing: true)
        await minutes(60)
        watch.update(playing: false, visible: true)
        await minutes(60)
        XCTAssertEqual(actions, [])
    }

    func testPlayingOrLookingAgainStartsTheCountOver() async {
        await minutes(10)
        watch.update(visible: true)
        await minutes(30)
        watch.update(visible: false)
        await minutes(10)
        XCTAssertEqual(actions, [], "ten minutes since the last look is not fifteen")
        await minutes(6)
        XCTAssertEqual(actions, [.stopService])
    }

    func testAStopIsNotRepeatedWhileNothingChanges() async {
        await minutes(120)
        XCTAssertEqual(actions.count, 1)
    }

    func testJoiningARoomWhileQuietSwitchesToTheRoomsLongerWait() async {
        await minutes(10)
        watch.update(inRoom: true)
        await minutes(15)
        XCTAssertEqual(actions, [], "the wait began again in the room, and is twenty minutes")
        await minutes(6)
        XCTAssertEqual(actions, [.suspendRoom])
    }
}

@MainActor
final class RoomClientTests: XCTestCase {
    private let time = VirtualTime()
    private let scope = Scope()
    private let sockets = FakeSockets()
    private var clients: [RoomClient] = []

    private let state = #"{"t":"state","serverNow":0,"you":"me","state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":0},"members":[]}"#

    override func tearDown() async throws {
        clients.forEach { $0.close() }
        scope.cancel()
    }

    private func client(create: Bool?, pingEveryMs: Int64 = 30_000, pongDeadlineMs: Int64 = 45_000) -> RoomClient {
        let made = RoomClient(baseUrl: "https://unison.example.dev/", roomCode: "abc234", clientId: "me", name: "Me", scope: scope,
                              clock: ClockSync(), time: time, create: create, sockets: sockets, pingEveryMs: pingEveryMs,
                              pongDeadlineMs: pongDeadlineMs)
        clients.append(made)
        return made
    }

    private func joins(_ socket: FakeSocket) -> [String] { socket.sent.filter { $0.contains("\"join\"") } }

    func testTheAddressIsTheServersWebSocketForTheRoom() async {
        client(create: false).start()
        await time.settle()
        XCTAssertEqual(sockets.opened.first?.url.absoluteString, "wss://unison.example.dev/room/ABC234")
    }

    func testTheFirstJoinSaysWhatTheDeviceExpectsAndAReconnectNoLongerAsksToCreate() async {
        let client = client(create: true)
        client.start()
        await time.settle()
        let first = sockets.opened[0]
        first.open()
        XCTAssertTrue(joins(first)[0].contains("\"create\":true"), joins(first)[0])
        first.receive(state)
        first.events.socketEnded(code: 1001, reason: "going away")
        await time.advance(1000)
        XCTAssertEqual(client.connection.value, .reconnecting)
        let second = sockets.opened[1]
        second.open()
        XCTAssertTrue(joins(second)[0].contains("\"create\":false"), "a room that was made must not be made again: \(joins(second)[0])")
        XCTAssertEqual(client.connection.value, .connected)
    }

    func testAnOlderStyleJoinLeavesTheFlagOut() async {
        client(create: nil).start()
        await time.settle()
        sockets.opened[0].open()
        XCTAssertFalse(joins(sockets.opened[0])[0].contains("create"))
    }

    func testARoomThatDoesNotExistIsAFinalAnswer() async {
        let client = client(create: false)
        client.start()
        await time.settle()
        sockets.opened[0].open()
        sockets.opened[0].events.socketEnded(code: 4004, reason: "room not found")
        await time.advance(60_000)
        XCTAssertEqual(client.connection.value, .refused)
        XCTAssertEqual(sockets.opened.count, 1, "no retry after a refusal")
    }

    func testBeingRemovedOrAFullRoomIsRefusedForGoodToo() async {
        for code in [4001, 1008] {
            let sockets = FakeSockets()
            let client = RoomClient(baseUrl: "https://unison.example.dev", roomCode: "ABC234", clientId: "me", name: "Me", scope: scope,
                                    clock: ClockSync(), time: time, sockets: sockets)
            client.start()
            await time.settle()
            sockets.opened[0].open()
            sockets.opened[0].events.socketEnded(code: code, reason: "no")
            await time.advance(30_000)
            XCTAssertEqual(client.connection.value, .refused, "close code \(code)")
            XCTAssertEqual(sockets.opened.count, 1)
            client.close()
        }
    }

    func testTheServersWordsTellTheRefusalWhenTheSystemDoesNotPassTheCodeOn() async {
        let client = client(create: false)
        client.start()
        await time.settle()
        sockets.opened[0].open()
        sockets.opened[0].events.socketEnded(code: 0, reason: "removed by the owner")
        await time.advance(30_000)
        XCTAssertEqual(client.connection.value, .refused)
    }

    func testAWrongKeyIsNotRetried() async {
        let client = client(create: false)
        client.start()
        await time.settle()
        sockets.opened[0].events.socketFailed(URLError(.userAuthenticationRequired), httpStatus: 401)
        await time.advance(60_000)
        XCTAssertEqual(client.connection.value, .unauthorized)
        XCTAssertEqual(sockets.opened.count, 1)
    }

    func testLeavingOnPurposeTellsTheRoom() async {
        let client = client(create: false)
        client.start()
        await time.settle()
        let socket = sockets.opened[0]
        socket.open()
        client.leave()
        XCTAssertTrue(socket.sent.contains { $0.contains("\"bye\"") }, "the room should hear bye before the socket closes")
        XCTAssertEqual(client.connection.value, .closed)
    }

    func testAConnectionThatStopsAnsweringPingsIsDroppedAndRejoined() async {
        let client = client(create: false, pingEveryMs: 100, pongDeadlineMs: 300)
        client.start()
        await time.settle()
        sockets.opened[0].open()
        await time.advance(2_000 + 1_500) // the burst of first pings, a silent while, and the wait before the retry
        XCTAssertGreaterThanOrEqual(sockets.opened.count, 2, "the silent connection should have been replaced")
        XCTAssertTrue(sockets.opened[0].cancelled)
        _ = client
    }

    func testAConnectionThatAnswersItsPingsIsLeftAlone() async {
        let client = client(create: false, pingEveryMs: 100, pongDeadlineMs: 800)
        client.start()
        await time.settle()
        let socket = sockets.opened[0]
        socket.open()
        var answered = 0
        for _ in 0..<80 {
            await time.advance(50)
            while answered < socket.sent.count {
                let text = socket.sent[answered]
                answered += 1
                if let c0 = JSON.parse(text)?.at("c0").int64, JSON.parse(text)?.at("t").string == "ping" {
                    socket.receive(#"{"t":"pong","c0":\#(c0),"s1":0}"#)
                }
            }
        }
        XCTAssertEqual(sockets.opened.count, 1, "a healthy connection must not be replaced")
        XCTAssertEqual(client.connection.value, .connected)
    }

    func testReconnectNowDoesNotWaitOutTheBackoff() async {
        let client = client(create: false)
        client.start()
        await time.settle()
        sockets.opened[0].open()
        client.reconnectNow()
        await time.advance(10)
        XCTAssertEqual(sockets.opened.count, 2, "a connection that may be dead is replaced at once")
    }

    func testRenamingSendsAJoinWithoutDroppingTheConnection() async {
        let client = client(create: false)
        client.start()
        await time.settle()
        let socket = sockets.opened[0]
        socket.open()
        client.rename("New name")
        XCTAssertEqual(joins(socket).count, 2)
        XCTAssertTrue(joins(socket)[1].contains("New name"))
        XCTAssertEqual(client.connection.value, .connected)
    }
}

final class WireTests: XCTestCase {
    func testTheServersMessagesAreRead() throws {
        guard case let .state(serverNow, you, state, members, version)? = Wire.parse(
            #"{"t":"state","serverNow":5,"you":"me","protocol":6,"state":{"queue":[{"id":"q","videoId":"v","title":"T","artist":"A","durMs":9,"addedBy":"x"}],"index":0,"phase":"playing","startedAt":10,"positionMs":0,"epoch":3,"repeat":"all","name":"Room","ownerId":"me","guestControl":"add"},"members":[{"id":"me","name":"Me","ready":true,"owner":true}]}"#
        ) else { return XCTFail("not a state") }
        XCTAssertEqual(serverNow, 5)
        XCTAssertEqual(you, "me")
        XCTAssertEqual(version, 6)
        XCTAssertEqual(state.phase, "playing")
        XCTAssertEqual(state.repeatMode, "all")
        XCTAssertEqual(state.guestControl, "add")
        XCTAssertEqual(state.current?.title, "T")
        XCTAssertEqual(members, [Member(id: "me", name: "Me", ready: true, owner: true)])
    }

    func testAnOlderServerLeavesOutWhatIsNew() throws {
        guard case let .state(_, _, state, _, version)? = Wire.parse(
            #"{"t":"state","serverNow":0,"you":"me","state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":0},"members":[]}"#
        ) else { return XCTFail("not a state") }
        XCTAssertEqual(version, 0)
        XCTAssertEqual(state.repeatMode, "off")
        XCTAssertEqual(state.guestControl, "all")
        XCTAssertNil(state.name)
    }

    func testTheOtherMessages() {
        XCTAssertEqual(Wire.parse(#"{"t":"pong","c0":1,"s1":2}"#), .pong(c0: 1, s1: 2))
        XCTAssertEqual(Wire.parse(#"{"t":"pause","epoch":4,"positionMs":900,"by":"x"}"#), .pause(epoch: 4, positionMs: 900, by: "x"))
        XCTAssertEqual(Wire.parse(#"{"t":"start","epoch":4,"startAt":77,"positionMs":0}"#), .start(epoch: 4, startAt: 77, positionMs: 0, by: nil))
        XCTAssertEqual(Wire.parse(#"{"t":"advance","epoch":5,"index":1,"startedAt":8}"#), .advance(epoch: 5, index: 1, startedAt: 8))
        XCTAssertEqual(Wire.parse(#"{"t":"error","code":"forbidden","message":"No"}"#), .error(code: "forbidden", message: "No"))
        XCTAssertEqual(Wire.parse(#"{"t":"members","members":[]}"#), .members([]))
    }

    func testWhatIsNotUnderstoodIsIgnored() {
        XCTAssertNil(Wire.parse("hello"))
        XCTAssertNil(Wire.parse(#"{"t":"nope"}"#))
        XCTAssertNil(Wire.parse(#"{"t":"pong"}"#))
        XCTAssertNil(Wire.parse(#"[1,2]"#))
    }

    func testWhatIsSentIsWhatTheServerKnows() {
        func object(_ text: String) -> [String: Any] { JSON.parse(text)?.object ?? [:] }
        let join = object(Wire.join(clientId: "me", name: "Me", create: true))
        XCTAssertEqual(join["t"] as? String, "join")
        XCTAssertEqual(join["clientId"] as? String, "me")
        XCTAssertEqual(join["create"] as? Bool, true)
        XCTAssertNil(object(Wire.join(clientId: "me", name: "Me"))["create"])

        let add = object(Wire.queueAdd(TrackRef(videoId: "v", title: "T", artist: "A", thumb: nil, durMs: 5), playNext: true))
        XCTAssertEqual(add["t"] as? String, "queue.add")
        XCTAssertEqual(add["next"] as? Bool, true)
        XCTAssertNil(add["thumb"])

        let many = object(Wire.queueAddMany([TrackRef(videoId: "v", title: "T", artist: "A", thumb: "u", durMs: 5)]))
        XCTAssertEqual((many["tracks"] as? [[String: Any]])?.first?["thumb"] as? String, "u")
        XCTAssertNil(many["next"])

        XCTAssertEqual(object(Wire.queueMove("q", toIndex: 2))["toIndex"] as? Int, 2)
        XCTAssertEqual(object(Wire.seek(1234))["positionMs"] as? Int, 1234)
        XCTAssertEqual(object(Wire.advanced(3, itemId: "q", startedAt: 99))["startedAt"] as? Int, 99)
        XCTAssertEqual((object(Wire.resolveFailed(3, reason: String(repeating: "x", count: 500)))["reason"] as? String)?.count, 200)
        XCTAssertEqual(object(Wire.roomSettings(guestControl: "add"))["guestControl"] as? String, "add")
        XCTAssertEqual(object(Wire.bye())["t"] as? String, "bye")
    }
}

final class SmallPartsTests: XCTestCase {
    func testTheCloserTheSampleTheMoreItCounts() {
        let clock = ClockSync()
        XCTAssertFalse(clock.hasSync())
        clock.addSample(c0: 0, c2: 200, s1: 5100) // offset 5000, slow
        clock.addSample(c0: 1000, c2: 1020, s1: 6010 + 5) // offset 5005, fast
        XCTAssertEqual(clock.bestRttMs(), 20)
        XCTAssertEqual(clock.offsetMs(), 5005)
        XCTAssertEqual(clock.toServer(100), 5105)
        XCTAssertEqual(clock.toLocal(5105), 100)
    }

    func testDriftIsAnsweredWithASpeedChangeOrASeek() {
        let controller = DriftController()
        XCTAssertEqual(controller.decide(10), .none)
        XCTAssertEqual(controller.decide(100), .setSpeed(0.97))
        XCTAssertEqual(controller.decide(60), .none, "still ahead: keep going")
        XCTAssertEqual(controller.decide(10), .setSpeed(1))
        XCTAssertEqual(controller.decide(-100), .setSpeed(1.03))
        XCTAssertEqual(controller.decide(-1000), .seek)
    }

    func testSongsAlreadyWaitingAreLeftOut() {
        func track(_ id: String) -> TrackRef { TrackRef(videoId: id, title: id, artist: "", thumb: nil, durMs: 1) }
        func item(_ id: String) -> QueueItem { QueueItem(id: "q" + id, videoId: id, title: id, artist: "", thumb: nil, durMs: 1, addedBy: "") }
        let queue = [item("a"), item("b"), item("c")]
        XCTAssertEqual(Queues.fresh([track("a"), track("d"), track("d"), track("c")], queue: queue, index: 1).map(\.videoId), ["a", "d"])
    }

    func testOnlySongsAreSuggestedOneFromEachListInTurn() {
        func track(_ id: String, _ seconds: Int64) -> TrackRef { TrackRef(videoId: id, title: id, artist: "", thumb: nil, durMs: seconds * 1000) }
        let first = [track("a1", 200), track("a2", 200), track("mix", 3600), track("a3", 200)]
        let second = [track("b1", 200), track("a1", 200), track("b2", 30), track("b3", 200)]
        let mixed = Suggestions.mix([first, second], exclude: ["a2"], limit: 5)
        XCTAssertEqual(mixed.map(\.videoId), ["a1", "b1", "a3", "b3"])
    }

    func testVideoStreamsAreChosenByHeightAndOnlyH264Plays() {
        func source(_ height: Int, _ codec: String = "avc1.4d401f", _ kbps: Int = 1000) -> VideoSource {
            VideoSource(url: "u\(height)\(codec)", height: height, codec: codec, bitrateKbps: kbps, itag: height)
        }
        let sources = [source(1080), source(720), source(480), source(360)]
        XCTAssertEqual(VideoPicker.pick(sources, maxHeight: 720)?.height, 720)
        XCTAssertEqual(VideoPicker.pick(sources, maxHeight: 360)?.height, 360)
        XCTAssertEqual(VideoPicker.pick(sources, maxHeight: 2160)?.height, 1080)
        XCTAssertEqual(VideoPicker.pick([source(2160), source(1080)], maxHeight: 720)?.height, 1080, "the smallest when all are taller")
        XCTAssertNil(VideoPicker.pick([source(720, "vp09.00.40.08")], maxHeight: 720), "an iPhone does not play VP9")
        XCTAssertNil(VideoPicker.pick([], maxHeight: 720))
        XCTAssertEqual(VideoPicker.pick([source(720, "avc1.a", 500), source(720, "avc1.b", 900)], maxHeight: 720)?.bitrateKbps, 900)
    }

    func testTheVideoStreamsOfAnAnswerAreTheH264OnesInMP4() throws {
        let answer = try XCTUnwrap(JSON.parse(data: fixture("player_visionos")))
        let resolved = try YouTubeResolver.resolved(answer, videoId: "dQw4w9WgXcQ")
        XCTAssertFalse(resolved.videos.isEmpty)
        XCTAssertTrue(resolved.videos.allSatisfy { $0.codec.hasPrefix("avc1") && $0.height > 0 })
        XCTAssertEqual(VideoPicker.pick(resolved.videos, maxHeight: 720)?.height, 720)
    }

    func testAnAddressThatCannotBeUsedCountsAsNone() {
        XCTAssertFalse(ServerConfig(server: "").isSet)
        XCTAssertFalse(ServerConfig(server: "https://bad host").isSet)
        XCTAssertTrue(ServerConfig(server: "https://unison.example.dev").isSet)
    }

    @MainActor
    func testARoomCodeWithOddCharactersDoesNotBreakTheAddress() async {
        let sockets = FakeSockets()
        let scope = Scope()
        let client = RoomClient(baseUrl: "https://unison.example.dev", roomCode: " ab c/2é34 ", clientId: "me", name: "Me", scope: scope,
                                clock: ClockSync(), time: VirtualTime(), sockets: sockets)
        client.start()
        await Task.yield()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(sockets.opened.first?.url.absoluteString, "wss://unison.example.dev/room/ABC234")
        client.close()
        scope.cancel()
    }

    func testServerAddressesAreCleaned() {
        XCTAssertEqual(ServerConfig.clean(" unison.example.dev/ "), "https://unison.example.dev")
        XCTAssertEqual(ServerConfig.clean("http://10.0.0.2:8787//"), "http://10.0.0.2:8787")
        XCTAssertEqual(ServerConfig.clean(""), "")
        XCTAssertEqual(ServerConfig(server: "https://x", key: "k").authHeaders, ["X-Unison-Key": "k"])
        XCTAssertEqual(ServerConfig(server: "https://x", key: "").authHeaders, [:])
    }

    func testSettingsComeBackAsTheyWereKept() {
        let store = MemoryStore()
        ServerConfig(server: "https://x", key: "k").save(to: store)
        XCTAssertEqual(ServerConfig.load(store), ServerConfig(server: "https://x", key: "k"))
        XCTAssertNil(store.string("nothing"))
        XCTAssertTrue(store.bool("nothing", default: true))
    }
}

final class MediaTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func files(limit: Int64 = 1000) -> MediaFiles {
        MediaFiles(downloadsDir: dir.appendingPathComponent("d"), playDir: dir.appendingPathComponent("p"), playLimitBytes: limit)
    }

    private func write(_ url: URL, _ bytes: Int) throws {
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    func testAFileIsOnlyGivenItsNameOnceItIsAllThere() throws {
        let files = files()
        try write(files.part("abc", download: false), 10)
        XCTAssertNil(files.file("abc"))
        try files.finish("abc", download: false)
        XCTAssertEqual(files.file("abc"), files.played("abc"))
        XCTAssertEqual(files.playBytes(), 10)
    }

    func testDownloadsComeBeforeWhatWasPlayedAndWhatWasPlayedCanBeKept() throws {
        let files = files()
        try write(files.played("abc"), 10)
        XCTAssertFalse(files.isDownloaded("abc"))
        XCTAssertTrue(files.keepPlayed("abc"))
        XCTAssertTrue(files.isDownloaded("abc"))
        XCTAssertEqual(files.file("abc"), files.downloaded("abc"))
        XCTAssertEqual(files.size(ofDownload: "abc"), 10)
        XCTAssertEqual(files.playBytes(), 0)
        XCTAssertEqual(files.downloadBytes(), 10)
        XCTAssertFalse(files.keepPlayed("nothing"))
    }

    func testTheOldestPlayedSongsGoWhenTheCacheIsFull() throws {
        let files = files(limit: 25)
        for (index, name) in ["a", "b", "c"].enumerated() {
            try write(files.part(name, download: false), 10)
            try files.finish(name, download: false)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))], ofItemAtPath: files.played(name).path)
        }
        files.trimPlay()
        XCTAssertNil(files.file("a"))
        XCTAssertNotNil(files.file("b"))
        XCTAssertNotNil(files.file("c"))
        files.setPlayLimit(5)
        XCTAssertEqual(files.playBytes(), 0)
    }

    func testDownloadsAreNeverTrimmedAndCanBeRemovedOrCleared() throws {
        let files = files(limit: 1)
        try write(files.part("a", download: true), 50)
        try files.finish("a", download: true)
        files.trimPlay()
        XCTAssertTrue(files.isDownloaded("a"))
        files.removeDownload("a")
        XCTAssertFalse(files.isDownloaded("a"))
        try write(files.downloaded("b"), 5)
        files.clearDownloads()
        XCTAssertEqual(files.downloadBytes(), 0)
    }

    func testHalfWrittenFilesAreRemovedWhenTheFolderIsOpenedAgain() throws {
        let first = files()
        try write(first.part("abc", download: false), 10)
        _ = files()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.part("abc", download: false).path))
    }

    func testANameFromOutsideCannotPointOutOfTheFolder() {
        let files = files()
        XCTAssertEqual(files.played("../../evil").deletingLastPathComponent().lastPathComponent, "p")
    }

    private func library(_ resolver: FakeResolver, _ fetcher: FileFetcher, limit: Int64 = 1 << 20) -> (MediaLibrary, MediaFiles) {
        let files = files(limit: limit)
        return (MediaLibrary(files: files, streams: StreamCache(resolver: resolver), fetcher: fetcher), files)
    }

    func testASongIsFetchedOnceAndThenPlayedFromTheDisk() async throws {
        let counter = Counter()
        struct Counting: FileFetcher {
            let counter: Counter

            func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
                counter.bump()
                try Data(repeating: 7, count: 10).write(to: file)
                return 10
            }
        }
        let (media, files) = library(FakeResolver(), Counting(counter: counter))
        let first = try await media.playable("vid00000001")
        XCTAssertTrue(first.isFile)
        XCTAssertEqual(first.url, files.played("vid00000001"))
        _ = try await media.playable("vid00000001")
        XCTAssertEqual(counter.count, 1)
    }

    func testASongThatIsTooLongIsPlayedFromTheStream() async throws {
        final class Long: StreamResolver, @unchecked Sendable {
            func search(_ query: String, limit: Int, songsOnly: Bool) async throws -> [TrackInfo] { [] }
            func resolve(_ videoId: String) async throws -> Resolved {
                let source = AudioSource(url: "https://example.invalid/long", mimeType: "audio/mp4", bitrateKbps: 128, contentLength: MediaLibrary.wholeLimitBytes + 1, itag: 140)
                return Resolved(track: TrackInfo(videoId: videoId, title: "T", artist: "A", thumbUrl: nil, durationSec: 9000), best: source, all: [source], userAgent: "ua")
            }
            func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistRef] { [] }
            func playlist(_ playlistId: String, limit: Int) async throws -> Playlist { Playlist(title: "", tracks: []) }
            func related(_ videoId: String, limit: Int) async throws -> [TrackInfo] { [] }
            func suggest(_ query: String) async throws -> [String] { [] }
        }
        let files = files()
        let media = MediaLibrary(files: files, streams: StreamCache(resolver: Long()), fetcher: FakeFetcher())
        let playable = try await media.playable("vid00000001")
        XCTAssertFalse(playable.isFile)
        XCTAssertEqual(playable.url.absoluteString, "https://example.invalid/long")
        XCTAssertEqual(playable.headers["User-Agent"], "ua")
    }

    func testAFailedTransferIsTriedAgainWithAFreshAddressAndThenGivenUp() async throws {
        final class Flaky: FileFetcher, @unchecked Sendable {
            var failures: Int
            var calls = 0

            init(failures: Int) { self.failures = failures }

            func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
                calls += 1
                if failures > 0 {
                    failures -= 1
                    throw URLError(.networkConnectionLost)
                }
                try Data(repeating: 7, count: 10).write(to: file)
                return 10
            }
        }
        let works = Flaky(failures: 2)
        let (media, _) = library(FakeResolver(), works)
        let playable = try await media.playable("vid00000001")
        XCTAssertTrue(playable.isFile)
        XCTAssertEqual(works.calls, 3)

        let broken = Flaky(failures: 100)
        let (other, _) = library(FakeResolver(), broken)
        do {
            _ = try await other.playable("vid00000002")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(broken.calls, 3)
        }
    }

    func testASharedTransferGoesOnWhenOnlyOneOfTheTwoWaitingGivesUp() async throws {
        final class Slow: FileFetcher, @unchecked Sendable {
            let lock = NSLock()
            var calls = 0

            func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
                lock.lock()
                calls += 1
                lock.unlock()
                try await Task.sleep(nanoseconds: 150_000_000)
                try Data(repeating: 7, count: 10).write(to: file)
                return 10
            }
        }
        let slow = Slow()
        let (media, files) = library(FakeResolver(), slow)
        let preload = Task { try await media.playable("vid00000001") }
        try await Task.sleep(nanoseconds: 20_000_000)
        let play = Task { try await media.playable("vid00000001") }
        try await Task.sleep(nanoseconds: 20_000_000)
        preload.cancel() // the next song was changed while it was being fetched
        let playable = try await play.value
        XCTAssertTrue(playable.isFile)
        XCTAssertEqual(slow.calls, 1, "one transfer served both")
        XCTAssertNotNil(files.file("vid00000001"))
    }

    func testATransferNobodyWaitsForAnyMoreIsStopped() async throws {
        final class Slow: FileFetcher, @unchecked Sendable {
            let lock = NSLock()
            var finished = false

            func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
                try await Task.sleep(nanoseconds: 300_000_000)
                lock.lock()
                finished = true
                lock.unlock()
                return 10
            }
        }
        let slow = Slow()
        let (media, files) = library(FakeResolver(), slow)
        let only = Task { try await media.playable("vid00000001") }
        try await Task.sleep(nanoseconds: 30_000_000)
        only.cancel()
        do {
            _ = try await only.value
            XCTFail("expected the cancel to reach the caller")
        } catch is CancellationError {
            // as it should
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(slow.finished, "the transfer was stopped with its only waiter")
        XCTAssertNil(files.file("vid00000001"))
    }

    func testAShortTransferIsNotKept() async throws {
        struct Short: FileFetcher {
            func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
                try Data(repeating: 7, count: 4).write(to: file)
                return 4
            }
        }
        let (media, files) = library(FakeResolver(), Short())
        do {
            _ = try await media.playable("vid00000001")
            XCTFail("expected a failure")
        } catch {
            XCTAssertNil(files.file("vid00000001"))
        }
    }

    func testDownloadingKeepsTheSongForGoodAndReusesWhatWasPlayed() async throws {
        let (media, files) = library(FakeResolver(), FakeFetcher())
        _ = try await media.playable("vid00000001")
        let bytes = try await media.download("vid00000001")
        XCTAssertEqual(bytes, 10)
        XCTAssertTrue(files.isDownloaded("vid00000001"))
        XCTAssertEqual(files.playBytes(), 0, "the played copy was moved, not fetched twice")
        let fresh = try await media.download("vid00000002")
        XCTAssertEqual(fresh, 10)
        XCTAssertTrue(files.isDownloaded("vid00000002"))
    }

    func testTheStreamCacheResolvesOnceAtATimeAndForgetsOnRequest() async throws {
        final class Counting: StreamResolver, @unchecked Sendable {
            var resolves = 0
            func search(_ query: String, limit: Int, songsOnly: Bool) async throws -> [TrackInfo] { [] }
            func resolve(_ videoId: String) async throws -> Resolved {
                resolves += 1
                try await Task.sleep(nanoseconds: 20_000_000)
                let source = AudioSource(url: "https://example.invalid/\(resolves)", mimeType: "audio/mp4", bitrateKbps: 128, contentLength: 1, itag: 140)
                return Resolved(track: TrackInfo(videoId: videoId, title: "T", artist: "A", thumbUrl: nil, durationSec: 1), best: source, all: [source], userAgent: "ua")
            }
            func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistRef] { [] }
            func playlist(_ playlistId: String, limit: Int) async throws -> Playlist { Playlist(title: "", tracks: []) }
            func related(_ videoId: String, limit: Int) async throws -> [TrackInfo] { [] }
            func suggest(_ query: String) async throws -> [String] { [] }
        }
        let resolver = Counting()
        let cache = StreamCache(resolver: resolver)
        async let first = cache.audio("v")
        async let second = cache.audio("v")
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(resolver.resolves, 1, "a preload and a play must not race")
        _ = try await cache.audio("v")
        XCTAssertEqual(resolver.resolves, 1)
        await cache.invalidate("v")
        let again = try await cache.audio("v")
        XCTAssertEqual(resolver.resolves, 2)
        XCTAssertNotEqual(again, a)
    }
}

final class FeedsTests: XCTestCase {
    func testTheDownloaderTakesSongsOneAtATimeAndSetsFailuresAside() async throws {
        let store = try LibraryStore(path: ":memory:")
        func song(_ id: String) -> TrackRef { TrackRef(videoId: id, title: id, artist: "", thumb: nil, durMs: 1000) }
        try await store.requestDownloads([song("a"), song("bad"), song("c")])
        let log = Collected2()
        let downloader = Downloader(store: store, fetch: { id in
            await log.add(id)
            if id == "bad" { throw URLError(.networkConnectionLost) }
            return 5
        })
        let result = try await downloader.drain(waiting: false)
        XCTAssertEqual(result, Downloader.Result(done: 2, retryLater: true))
        let tried = await log.items
        XCTAssertEqual(tried, ["a", "bad", "c"], "the failed one is not taken again in the same run")
        let states = try await store.downloads().map { "\($0.track.videoId) \($0.state)" }
        XCTAssertEqual(Set(states.prefix(2)), ["a done", "c done"], "what is on the phone comes first")
        XCTAssertEqual(states.last, "bad queued")
    }

    func testSuggestionsComeFromTheSeedsAndKeepForHalfADay() async throws {
        let store = try LibraryStore(path: ":memory:")
        func song(_ id: String, _ seconds: Int64 = 200) -> TrackRef { TrackRef(videoId: id, title: id, artist: "", thumb: nil, durMs: seconds * 1000) }
        try await store.setLiked(song("seed"), true, at: 1_000)
        let resolver = FakeResolver()
        resolver.results = [
            TrackInfo(videoId: "rel00000001", title: "R1", artist: "A", thumbUrl: nil, durationSec: 200),
            TrackInfo(videoId: "rel00000002", title: "R2", artist: "A", thumbUrl: nil, durationSec: 20),
        ]
        let clock = Collected2()
        let music = MusicFeed(music: MusicClient { _, _ in JSON.parse("{}")! }, lyricsClient: LyricsClient { _ in nil },
                              lyricsStore: LyricsStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent("l-\(UUID().uuidString)")))
        _ = clock
        let feed = SuggestionFeed(store: store, resolver: resolver, music: music, now: { 5_000 })
        var offered = try await feed.forYou()
        XCTAssertEqual(offered, [], "nothing until the lists were fetched once")
        let changed = try await feed.renew(force: false)
        XCTAssertTrue(changed)
        offered = try await feed.forYou()
        XCTAssertEqual(offered.map(\.videoId), ["rel00000001"], "songs only, and not the seed itself")
        let again = try await feed.renew(force: false)
        XCTAssertFalse(again, "fresh lists are not fetched again")
        let lists = try await feed.seedLists()
        XCTAssertEqual(lists.first?.seed, "seed")
        let after = try await feed.after("seed", exclude: [], count: 5)
        XCTAssertEqual(after.map(\.videoId), ["rel00000001"])
    }
}

actor Collected2 {
    private(set) var items: [String] = []

    func add(_ item: String) { items.append(item) }
}
