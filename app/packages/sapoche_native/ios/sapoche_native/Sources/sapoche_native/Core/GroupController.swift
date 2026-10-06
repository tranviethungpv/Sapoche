import Foundation

/// What the player looks like from outside, for the screen.
struct PlayerInfo: Equatable {
    var playing = false
    var buffering = false
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var videoWidth = 0
    var videoHeight = 0
    /// The picture is wanted but this song plays without one.
    var noPicture = false
    /// Paused on this device while the room plays on, see `GroupController.heldBack`.
    var heldBack = false
    /// How fast the player plays: the person's choice outside a room, the drift control's in one.
    var speed: Float = 1
}

/// A [PlayerPort] with what the controller needs beyond the session's needs: volume for the sleep timer's fade, a way to
/// pause at the end of the song, and what the screen shows.
@MainActor
protocol PlayerEngine: PlayerPort {
    /// The song that is loaded, or nil when nothing is or it has ended.
    var loadedItem: QueueItem? { get }

    /// Sound is wanted: playing, or about to (loading, buffering).
    var wantsSound: Bool { get }

    func playerInfo() -> PlayerInfo

    /// Resumes only this device's player, for when the room is playing and this device stopped by itself.
    func resumeLocally()

    func setVolume(_ volume: Float)

    /// Asks the player to pause when the song that plays now is over.
    func setPauseAtSongEnd(_ on: Bool)

    /// Called when something that the screen shows about the player changed: playing, buffering, a seek, another song.
    var onChange: (() -> Void)? { get set }

    /// Called when the player paused at the end of a song because of [setPauseAtSongEnd], or the queue ran out.
    var onSongEndPause: (() -> Void)? { get set }

    /// Called when something outside the app stopped the sound: a call, another app, the headphones going away.
    var onHold: (() -> Void)? { get set }

    /// Called when the system says an interruption is over and the sound may go on; without it the engine plays by itself.
    var onResumeAfterInterruption: (() -> Void)? { get set }

    /// Play songs with their picture ([on]) or sound only.
    func setVideoMode(_ on: Bool)

    /// The picture is on screen ([visible]) or not; when it is not, it is neither downloaded nor decoded.
    func setVideoVisible(_ visible: Bool)

    /// The id of the texture the picture is drawn into; throws where pictures cannot be played.
    func videoSurface() throws -> Int64

    /// Somebody watches the picture ([on]: it is on screen and playing, [width] x [height] pixels): the screen stays
    /// on, and leaving the app moves the picture into a small window where the phone can do that.
    func setVideoWatching(_ on: Bool, width: Int, height: Int)

    /// Whether the phone can show the picture in a small window over other apps.
    func pictureInPictureSupported() -> Bool

    /// Moves the picture into a small window over other apps now.
    func startPictureInPicture()
}

struct VideoUnavailable: Error, LocalizedError {
    var errorDescription: String? { "Pictures cannot be played here" }
}

extension PlayerEngine {
    func setVideoMode(_ on: Bool) {}
    func setVideoVisible(_ visible: Bool) {}
    func videoSurface() throws -> Int64 { throw VideoUnavailable() }
    func setVideoWatching(_ on: Bool, width: Int, height: Int) {}
    func pictureInPictureSupported() -> Bool { false }
    func startPictureInPicture() {}
}

/// Lives as long as the app, so the room connection survives the screen. While joined, the room decides what plays;
/// while not joined, the player plays the personal queue, like any music player.
@MainActor
final class GroupController {
    /// What the UI shows: the room as last announced, plus the connection to it, and the personal queue for outside a room.
    struct View: Equatable {
        var roomCode: String?
        var connection: Connection?
        var snapshot = GroupSession.Snapshot()
        var local = LocalSession.Snapshot()
    }

    /// Something another member did that moved this device, with their name already looked up.
    struct Notice: Equatable {
        let kind: String
        let by: String
        var title: String?
    }

    struct NoRoom: Error {}

    private let engine: PlayerEngine
    private let prefs: KeyValueStore
    private let time: TimeSource
    private let queueFile: QueueFile
    private let config: () -> ServerConfig
    /// Up to [Int] songs to carry on with after [String] (a video id), leaving out the ids given.
    private let moreLike: (String, Set<String>, Int) async throws -> [TrackRef]
    private let sockets: SocketFactory?
    private let clock = ClockSync()
    private let writer = DispatchQueue(label: "sapoche.queue-writer")

    /// Lives as long as this controller; [scope] is replaced each time a room is left.
    private let ownScope = Scope()
    private var scope = Scope()

    /// The queue that plays outside a room; it comes back after a restart, paused.
    private(set) var local: LocalSession!

    /// Stops this device after a while, or when the song is over; the fade is the player's own volume.
    private(set) var sleep: SleepTimer!

    private var client: RoomClient?
    private var session: GroupSession?
    private var autoplayJob: Job?
    private var radioJob: Job?
    private var idle: IdleWatch?
    private var recorder: ListenRecorder?

    let view: StateFlow<View>

    /// Errors reported to this device, e.g. a track nobody could play.
    let errors = SharedFlow<ControllerError>()
    let notices = SharedFlow<Notice>()

    /// A member's picture, as base64; [data] is nil when they have none (any more).
    struct Avatar: Equatable {
        let id: String
        let data: String?
    }

    let avatars = SharedFlow<Avatar>()

    /// The latest picture of each member, for a screen that comes back after pictures arrived.
    private var pictures: [String: String] = [:]

    func picturesSeen() -> [Avatar] {
        pictures.map { Avatar(id: $0.key, data: $0.value) }
    }

    /// Chat messages of room [room]: all it keeps when [replace], else new ones to add.
    struct Chat: Equatable {
        let room: String
        let messages: [ChatMessage]
        let replace: Bool
    }

    let chat = SharedFlow<Chat>()

    /// The room's chat as last heard; nil until the room sent its history (a server older than protocol 10 never does).
    private var chatLog: [ChatMessage]?

    /// The whole chat, for a screen that comes back after messages arrived.
    func chatSeen() -> Chat? {
        guard let roomCode, let chatLog else { return nil }
        return Chat(room: roomCode, messages: chatLog, replace: true)
    }

    /// Member [by] reacted with [e], [n] taps of it.
    struct Reaction: Equatable {
        let by: String
        let e: String
        let n: Int
    }

    let reactions = SharedFlow<Reaction>()

    /// Sends a chat message; false when there is no connection to send it on.
    func sendChat(_ text: String, cid: String) -> Bool { client?.send(Wire.chat(text, cid: cid)) ?? false }

    func react(_ e: String, n: Int) { client?.send(Wire.react(e, n: n)) }

    /// The picture this device shows the room as its own, as base64 of a small JPEG; nil for none. Kept across restarts.
    func setAvatar(_ data: String?) {
        prefs.set(data, for: Self.keyAvatar)
        client?.setAvatar(data)
    }

    /// The player did something the screen should show at once.
    let playerChanged = SharedFlow<Void>()

    private(set) var roomCode: String?

    var isActive: Bool { client != nil }

    /// The connection was let go of after a long idle spell, see [suspendRoom].
    private var suspended = false

    /// Commands given while [suspended], sent once the connection is back.
    private var pending: [String] = []

    /// The screen is on and the app is in front.
    private(set) var uiVisible = false

    /// Per-device latency correction in ms, see [GroupSession.trimMs].
    private(set) var trimMs: Int64

    /// Songs are played with their picture; this device's choice, remembered across runs.
    private(set) var videoMode: Bool

    init(engine: PlayerEngine, prefs: KeyValueStore, queueFile: QueueFile, config: @escaping () -> ServerConfig,
         recordListen: @escaping (TrackRef) -> Void = { _ in }, recordSkip: @escaping (TrackRef) -> Void = { _ in },
         time: TimeSource? = nil, sockets: SocketFactory? = nil,
         moreLike: @escaping (String, Set<String>, Int) async throws -> [TrackRef] = { _, _, _ in [] }) {
        self.engine = engine
        self.prefs = prefs
        self.queueFile = queueFile
        self.config = config
        self.time = time ?? SystemTime.shared
        self.sockets = sockets
        self.moreLike = moreLike
        trimMs = prefs.int64(Self.keyTrimMs) ?? 0
        videoMode = prefs.bool(Self.keyVideo, default: false)
        view = StateFlow(View())

        local = LocalSession(
            scope: ownScope,
            player: engine,
            saved: queueFile.read(),
            persist: { [writer, queueFile] saved in writer.async { queueFile.write(saved) } },
            problem: { [weak self] problem in
                // The title, and on a second line what went wrong, for whoever fixes the app
                let text = problem.detail.isEmpty ? problem.title : "\(problem.title)\n\(problem.detail)"
                self?.errors.emit(ControllerError(code: problem.kind.rawValue, message: text))
            },
            log: { EventLog.d("local", $0) },
            onQueueEnd: { [weak self] last in self?.autoplay(after: last) },
            time: self.time
        )
        sleep = SleepTimer(
            scope: ownScope,
            time: self.time,
            wallClock: { Int64(Date().timeIntervalSince1970 * 1000) },
            stop: { [weak self] in self?.stopForSleep() },
            fade: { [weak engine] in engine?.setVolume($0) },
            pauseAtSongEnd: { [weak engine] in engine?.setPauseAtSongEnd($0) }
        )
        recorder = ListenRecorder(engine: engine, time: self.time, scope: ownScope, record: recordListen, recordSkip: recordSkip)
        local.attach()
        engine.setVideoMode(videoMode)
        view.set(View(local: local.snapshot.value))

        // After the personal queue's own listener: when the last song ends it must see the timer still set
        // Behind the personal queue's own work on the same end (that is already waiting its turn): when the last song ends
        // it must see the timer still set
        engine.onSongEndPause = { [weak self] in
            self?.ownScope.launch { [weak self] in self?.sleep.songEnded() }
        }
        // A call, another app or the headphones stopped the sound: in a room this device stays quiet until its person
        // presses play (or the system says the interruption is over), whatever the room does meanwhile
        engine.onHold = { [weak self] in self?.session?.hold() }
        engine.onResumeAfterInterruption = { [weak self] in self?.requestPlay() }
        engine.onChange = { [weak self] in
            guard let self else { return }
            self.recorder?.changed()
            self.playerChanged.emit(())
            self.updateIdle()
        }
        ownScope.collect(local.snapshot) { [weak self] _ in self?.publish() }

        // Nobody listening or looking for a long while in a room: let go of the connection, whose pings keep the radio awake
        idle = IdleWatch(scope: ownScope, time: self.time, roomAfterMs: Self.roomIdleMs, serviceAfterMs: nil) { [weak self] action in
            if action == .suspendRoom {
                EventLog.d("sync", "nobody is listening or looking, letting go of the connection")
                self?.suspendRoom()
            }
        }
        updateIdle()
    }

    private func updateIdle() {
        idle?.update(inRoom: roomCode != nil, playing: engine.wantsSound, visible: uiVisible)
    }

    /// The screen came or went.
    func setUiVisible(_ visible: Bool) {
        uiVisible = visible
        updateIdle()
    }

    // ------------------------------------------------------------------ autoplay

    /// Whether the music carries on by itself when the queue runs out.
    var autoplayOn: Bool {
        get { prefs.bool(Self.keyAutoplay, default: true) }
        set { prefs.set(newValue, for: Self.keyAutoplay) }
    }

    /// The personal queue ran out. Unless the person turned it off, it carries on with songs like the last one, so the
    /// music does not just stop. Nothing happens without a network, in a room, or when they asked for something else in
    /// the meantime.
    private func autoplay(after last: QueueItem) {
        if !autoplayOn || session != nil || autoplayJob?.isActive == true || sleep.state.value == .songEnd { return }
        autoplayJob = ownScope.launch { [weak self] in
            guard let self else { return }
            do {
                let queued = Set(self.local.snapshot.value.queue.map(\.videoId))
                let more = try await self.moreLike(last.videoId, queued, Self.autoplayCount)
                if more.isEmpty || self.session != nil || !self.local.snapshot.value.finished { return }
                EventLog.d("local", "autoplay adds \(more.count) songs like '\(last.title)'")
                // A queue that has grown long by carrying on is started afresh rather than filling up
                if self.local.snapshot.value.queue.count > Self.autoplayRestartAt { self.local.clear() }
                self.local.add(more, next: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                EventLog.d("local", "autoplay found nothing: \(error.localizedDescription)")
            }
        }
    }

    /// The room's queue ran out and the server asked this device for songs like the last one, as [autoplay] does for the
    /// personal queue. Nothing is sent when the room has moved on by the time they arrive, or when none were found.
    private func fillRoom(epoch: Int64, videoId: String, title: String) {
        scope.launch { [weak self] in
            guard let self else { return }
            do {
                let more = try await self.moreLike(videoId, Set(self.queue().map(\.videoId)), Self.autoplayCount)
                if more.isEmpty || self.session?.snapshot.value.state?.epoch != epoch { return }
                EventLog.d("sync", "autoplay adds \(more.count) songs like '\(title)' to the room")
                self.send(Wire.queueAddMany(more))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                EventLog.d("sync", "autoplay found nothing for the room: \(error.localizedDescription)")
            }
        }
    }

    /// A song was started on its own, from a search or a shelf. Like YouTube Music, the queue fills with songs like it, so
    /// skipping works at once and the music carries on. Nothing is added when autoplay is off, in a room, or when the
    /// person has changed the queue by the time the songs arrive.
    func requestRadio(_ videoId: String) {
        radioJob?.cancel()
        if !autoplayOn || session != nil { return }
        radioJob = ownScope.launch { [weak self] in
            guard let self else { return }
            do {
                // The song that was tapped comes first: on a slow network the two would share it
                while self.local.snapshot.value.loading {
                    try await self.time.sleep(ms: Self.radioWaitStepMs)
                }
                let more = try await self.moreLike(videoId, [videoId], Self.radioCount)
                let queue = self.local.snapshot.value.queue
                if more.isEmpty || self.session != nil || queue.count != 1 || queue[0].videoId != videoId { return }
                EventLog.d("local", "radio adds \(more.count) songs like \(videoId)")
                self.local.add(more, next: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                EventLog.d("local", "no radio for \(videoId): \(error.localizedDescription)")
            }
        }
    }

    /// The sleep timer ran out. In a room only this device stops: it carries on alone, paused, and the room plays on.
    private func stopForSleep() {
        guard let session else {
            local.pause()
            return
        }
        if !session.isSolo { session.goSolo() }
        session.soloPause()
    }

    func setVideoMode(_ on: Bool) {
        videoMode = on
        prefs.set(on, for: Self.keyVideo)
        engine.setVideoMode(on)
        EventLog.d("video", "picture \(on ? "on" : "off")")
    }

    /// The picture is on screen; when it is not, it is neither downloaded nor decoded.
    func setVideoVisible(_ visible: Bool) { engine.setVideoVisible(visible) }

    /// Where the player draws the picture; throws where pictures cannot be played.
    func videoSurface() throws -> Int64 { try engine.videoSurface() }

    func setVideoWatching(_ on: Bool, width: Int, height: Int) { engine.setVideoWatching(on, width: width, height: height) }
    func pictureInPictureSupported() -> Bool { engine.pictureInPictureSupported() }
    func startPictureInPicture() { engine.startPictureInPicture() }

    /// How fast the personal queue plays, 1 being normal. Not kept across runs, and 1 in a room, where the speed keeps
    /// the phones in step.
    private(set) var playbackSpeed: Float = 1

    /// Plays the personal queue faster or slower; in a room the speed is the drift control's, and this does nothing.
    func setPlaybackSpeed(_ speed: Float) {
        guard session == nil else { return }
        playbackSpeed = min(max(speed, Self.minSpeed), Self.maxSpeed)
        engine.setSpeed(playbackSpeed)
        EventLog.d("local", "speed \(playbackSpeed)")
    }

    static let minSpeed: Float = 0.25
    static let maxSpeed: Float = 2

    // ------------------------------------------------------------------ room

    /// [create] says whether the code was just made (true) or given to this device (false): a mistyped code must not open a room.
    func join(code: String, name: String, create: Bool) {
        // Without an address there is nothing to connect to, and the system refuses an address without a scheme
        guard config().isSet else {
            errors.emit(ControllerError(code: "not_configured", message: "The server is not set"))
            return
        }
        stopFollowing()
        local.detach()
        // The room plays at its own pace
        if playbackSpeed != 1 {
            playbackSpeed = 1
            engine.setSpeed(1)
        }
        let id = deviceId()
        let log = { (message: String) in EventLog.d("sync", message) }
        let settings = config()

        let newSession = GroupSession(scope: scope, player: engine, clock: clock, time: time,
                                      send: { [weak self] text in self?.client?.send(text) }, log: log)
        newSession.trimMs = trimMs
        newSession.startBiasMs = prefs.int64(Self.keyStartBiasMs) ?? 0
        newSession.onStartBiasLearned = { [weak self] in self?.prefs.set($0, for: Self.keyStartBiasMs) }
        let newClient = RoomClient(baseUrl: settings.server, roomCode: code, clientId: id, name: name, scope: scope, clock: clock,
                                   time: time, log: log, headers: settings.authHeaders, create: create, sockets: sockets)
        newClient.onMessage = { [weak self] message in
            if case let .error(code, text) = message { self?.errors.emit(ControllerError(code: code, message: text)) }
            if case let .autoplayFill(epoch, videoId, title) = message { self?.fillRoom(epoch: epoch, videoId: videoId, title: title) }
            self?.onChat(room: code.uppercased(), message)
            newSession.onMessage(message)
        }
        newClient.onAvatar = { [weak self] memberId, _, data in
            guard let self else { return }
            self.pictures[memberId] = data
            self.avatars.emit(Avatar(id: memberId, data: data))
        }
        newClient.setAvatar(prefs.string(Self.keyAvatar))
        newClient.onConnected = { [weak self, weak newClient] in
            newSession.onReconnected()
            self?.scope.launch { [weak self] in
                if let newClient { self?.flushPending(newClient) }
            }
        }

        session = newSession
        client = newClient
        suspended = false
        pending.removeAll()
        roomCode = code.uppercased()
        publish()
        updateIdle()
        scope.collect(newSession.snapshot) { [weak self] _ in self?.publish() }
        // Listening alone is remembered, so that a restart brings this device back to it instead of into the room's music
        scope.collect(newSession.snapshot) { [weak self] snapshot in
            self?.prefs.set(snapshot.solo, for: Self.keyRoomSolo)
            self?.prefs.set(snapshot.soloItemId, for: Self.keyRoomSoloItem)
        }
        scope.launch { [weak self] in
            while let self {
                self.prefs.set(Self.wallClockMs(), for: Self.keyLastActive)
                guard await self.time.wait(ms: Self.activeStampMs) else { return }
            }
        }
        scope.collect(newSession.events) { [weak self, weak newSession] event in
            guard let self, let newSession else { return }
            let members = newSession.snapshot.value.members
            func nameOf(_ id: String) -> String { members.first { $0.id == id }?.name ?? "" }
            switch event {
            case let .paused(byId): self.notices.emit(Notice(kind: "paused", by: nameOf(byId)))
            case let .skipped(byId, title): self.notices.emit(Notice(kind: "skipped", by: nameOf(byId), title: title))
            // Told as the personal queue tells it: the person may be the only one not hearing the song
            case let .loadFailed(title, reason): self.errors.emit(ControllerError(code: Self.loadFailureCode(reason), message: title))
            }
        }
        scope.collect(newClient.connection) { [weak self] connection in
            self?.publish()
            // Turned away for good (the room is full, gone, or the owner removed this device): back to the personal queue.
            // Posted, because leaving cancels the scope this is running in.
            if connection == .refused { DispatchQueue.main.async { Task { @MainActor in self?.leave() } } }
        }
        prefs.set(roomCode, for: Self.keyRoomCode)
        prefs.set(name, for: Self.keyRoomName)
        EventLog.d("sync", "joining room \(roomCode ?? "") as '\(name)' (\(id))")
        newClient.start()
    }

    /// The network came back or changed: connect again at once instead of waiting out the backoff.
    func networkChanged(changed: Bool) {
        guard let client else { return }
        if changed || client.connection.value != .connected {
            EventLog.d("sync", "network available, reconnecting now")
            client.reconnectNow()
        }
    }

    /// Leave on the user's request: the room is forgotten and will not be rejoined automatically.
    func leave() {
        prefs.remove(Self.keyRoomCode)
        prefs.remove(Self.keyRoomSolo)
        prefs.remove(Self.keyRoomSoloItem)
        stopFollowing()
    }

    /// Called when the app starts. A room is only rejoined when the system ended the app while this device was in it a
    /// moment ago, and listening alone comes back as such, paused. Opening the app any other time starts outside a room,
    /// on the personal queue.
    func recoverRoom() {
        guard let code = prefs.string(Self.keyRoomCode) else { return }
        let idleMs = Self.wallClockMs() - (prefs.int64(Self.keyLastActive) ?? 0)
        if idleMs < 0 || idleMs > Self.recoveryWindowMs {
            EventLog.d("sync", "not rejoining \(code), it was left \(idleMs / 1000)s ago")
            prefs.remove(Self.keyRoomCode)
            return
        }
        // Read before joining: joining writes the listening mode of the new session over these
        let alone = prefs.bool(Self.keyRoomSolo, default: false)
        let aloneOn = prefs.string(Self.keyRoomSoloItem)
        let name = prefs.string(Self.keyRoomName) ?? "iPhone"
        EventLog.d("sync", "rejoining \(code) after the app was ended\(alone ? ", on my own" : "")")
        join(code: code, name: name, create: false)
        if alone { session?.restoreSolo(itemId: aloneOn) }
    }

    /// Change the display name in the current room without interrupting playback.
    func rename(_ name: String) {
        prefs.set(name, for: Self.keyRoomName)
        client?.rename(name)
    }

    /// [deliberate]: the person left, so the room is told and an owner hands it over; otherwise the app is just going away.
    private func stopFollowing(deliberate: Bool = true) {
        guard let client else { return }
        EventLog.d("sync", "leaving room \(roomCode ?? "")")
        if deliberate { client.leave() } else { client.close() }
        session?.close()
        self.client = nil
        session = nil
        roomCode = nil
        suspended = false
        pending.removeAll()
        pictures.removeAll()
        chatLog = nil
        scope.cancel()
        scope = Scope()
        local.attach() // the personal queue gets the player back, paused where it was
        publish()
        updateIdle()
    }

    private func onChat(room: String, _ message: ServerMessage) {
        switch message {
        case let .chatHistory(messages):
            let kept = Array(messages.suffix(Self.chatKept))
            chatLog = kept
            chat.emit(Chat(room: room, messages: kept, replace: true))
        case let .chat(message):
            chatLog = Array(((chatLog ?? []) + [message]).suffix(Self.chatKept))
            chat.emit(Chat(room: room, messages: [message], replace: false))
        case let .react(by, e, n):
            reactions.emit(Reaction(by: by, e: e, n: n))
        default:
            break
        }
    }

    private func publish() {
        view.set(View(roomCode: roomCode, connection: client?.connection.value,
                      snapshot: session?.snapshot.value ?? GroupSession.Snapshot(), local: local.snapshot.value))
    }

    /// Sends a command to the room. If the connection was let go of, it is brought back and the command goes when it is up.
    @discardableResult
    func send(_ text: String) -> Bool {
        if suspended {
            pending.append(text)
            resumeRoom()
            return true
        }
        return client?.send(text) ?? false
    }

    /// Nobody has listened or looked for a long while: close the connection, because its pings keep the radio awake all
    /// day. The room, this device's place in it and whether it listens alone are all kept.
    func suspendRoom() {
        guard let client, !suspended else { return }
        suspended = true
        EventLog.d("sync", "letting go of the connection to \(roomCode ?? "")")
        client.close()
    }

    /// Someone is looking again, or asked for something: connect again.
    func resumeRoom() {
        guard suspended else { return }
        suspended = false
        EventLog.d("sync", "connecting to \(roomCode ?? "") again")
        client?.start()
    }

    private func flushPending(_ target: RoomClient) {
        if target !== client { return }
        pending.forEach { target.send($0) }
        pending.removeAll()
    }

    /// Play button. If the room is playing and only this device stopped (a phone call, another app took the audio), resume
    /// just this device and let the drift correction catch it up; restarting the whole room would interrupt everyone else.
    @discardableResult
    func requestPlay(resumeLocally: Bool = true) -> Bool {
        // This device could not load the room's song: load it again rather than press play on nothing
        if phase() == "playing", session?.catchUp() == true { return true }
        // Held back from outside while the room plays on: join the room where it is, not where the sound was lost
        if let session, !session.isSolo, phase() == "playing", session.isHeld || (resumeLocally && !engine.wantsSound) {
            session.resumeHere()
            return true
        }
        session?.unhold()
        return act({ $0.play() }, { $0.soloPlay() }) { send(Wire.play()) }
    }

    /// Something outside the app asked this device to pause: a headset button, AirPods taken out, the lock screen. In a
    /// room it pauses only this device, as when a call takes the sound, because the room is everybody's and such a command
    /// cannot tell a person's choice from an ear coming out. Pausing the room is what the buttons in the app do.
    @discardableResult
    func pauseFromOutside() -> Bool {
        guard let session, !session.isSolo else { return requestPause() }
        session.hold()
        engine.pause()
        return true
    }

    /// This device follows a room that is playing but its own player is paused: a headset, a call or an app that took the
    /// sound did that here and the room plays on. The play button then shows play, and resumes only this device.
    private var heldBack: Bool {
        guard let session else { return false }
        return !session.isSolo && phase() == "playing" && (session.isHeld || (session.isInSync && !engine.wantsSound))
    }

    /// Listening on this device alone: the room does not move it, and its buttons do not move the room.
    var isSolo: Bool { session?.isSolo == true }

    /// How the screen knows why this device could not load a song, see [LocalSession.Problem.Kind].
    private static func loadFailureCode(_ reason: LoadFailure.Reason?) -> String {
        switch reason {
        case .offline: return LocalSession.Problem.Kind.offline.rawValue
        case .unplayable: return LocalSession.Problem.Kind.unplayable.rawValue
        case nil: return LocalSession.Problem.Kind.failed.rawValue
        }
    }

    /// Stop following the room and carry on alone.
    func goSolo() { session?.goSolo() }

    /// Follow the room again.
    func rejoin() { session?.rejoin() }

    /// The room stopped and this device wants to go on: leave the room's transport and resume.
    func keepPlaying() {
        guard let session else { return }
        session.goSolo()
        session.soloPlay()
    }

    // Outside a room the buttons drive the personal queue; in a room they act on the room, or on this device alone
    @discardableResult func requestPause() -> Bool { act({ $0.pause() }, { $0.soloPause() }) { send(Wire.pause()) } }
    // Each names the song it was pressed on, so that it does nothing once somebody else already skipped it
    @discardableResult func requestNext() -> Bool { act({ $0.next() }, { $0.soloNext() }) { send(Wire.next(from: roomItemId())) } }
    @discardableResult func requestPrev() -> Bool { act({ $0.prev() }, { $0.soloPrev() }) { send(Wire.prev(from: roomItemId())) } }
    private func roomItemId() -> String? { session?.snapshot.value.state?.current?.id }
    @discardableResult func requestSeek(_ positionMs: Int64) -> Bool { act({ $0.seek(positionMs) }, { $0.soloSeek(positionMs) }) { send(Wire.seek(positionMs)) } }
    @discardableResult func requestJump(_ itemId: String) -> Bool { act({ $0.jump(itemId) }, { $0.soloJump(itemId) }) { send(Wire.jump(itemId)) } }

    /// The queue is the room's in a room, even while listening alone, and the personal one outside.
    private func onQueue(_ onLocal: (LocalSession) -> Void, _ onRoom: () -> Bool) -> Bool {
        if session == nil {
            onLocal(local)
            return true
        }
        return onRoom()
    }

    @discardableResult func requestClearQueue() -> Bool { onQueue({ $0.clear() }) { send(Wire.queueClear()) } }
    @discardableResult func requestShuffle() -> Bool { onQueue({ $0.shuffle() }) { send(Wire.queueShuffle()) } }
    @discardableResult func requestRepeat(_ mode: String) -> Bool { onQueue({ $0.setRepeat(mode) }) { send(Wire.repeatMode(mode)) } }
    @discardableResult func requestAddMany(_ tracks: [TrackRef], playNext: Bool) -> Bool {
        onQueue({ $0.add(tracks, next: playNext) }) {
            // What is waiting in the room's queue is not added twice
            let fresh = Queues.fresh(tracks, queue: queue(), index: session?.snapshot.value.state?.index ?? 0)
            return fresh.isEmpty || send(Wire.queueAddMany(fresh, playNext: playNext))
        }
    }
    @discardableResult func requestSwap(_ itemId: String, _ track: TrackRef) -> Bool { onQueue({ $0.swap(itemId, track) }) { send(Wire.queueSwap(itemId, track)) } }
    @discardableResult func requestRemove(_ itemId: String) -> Bool { onQueue({ $0.remove(itemId) }) { send(Wire.queueRemove(itemId)) } }
    @discardableResult func requestMove(_ itemId: String, _ toIndex: Int) -> Bool { onQueue({ $0.move(itemId, toIndex: toIndex) }) { send(Wire.queueMove(itemId, toIndex: toIndex)) } }

    // Only meaningful in a room
    @discardableResult func requestKick(_ memberId: String) -> Bool { send(Wire.kick(memberId)) }
    @discardableResult func requestRoomName(_ name: String) -> Bool { send(Wire.roomName(name)) }
    @discardableResult func requestRoomSettings(_ guestControl: String) -> Bool { send(Wire.roomSettings(guestControl: guestControl)) }
    @discardableResult func requestRoomAutoplay(_ on: Bool) -> Bool { send(Wire.autoplay(on)) }

    /// Runs the action for wherever the buttons act: outside a room, alone in a room, or on the room itself.
    private func act(_ onLocal: (LocalSession) -> Void, _ onSolo: (GroupSession) -> Void, _ onRoom: () -> Bool) -> Bool {
        guard let session else {
            onLocal(local)
            return true
        }
        if session.isSolo {
            onSolo(session)
            return true
        }
        return onRoom()
    }

    /// The room's current queue, for callers that need item ids.
    func queue() -> [QueueItem] { session?.snapshot.value.state?.queue ?? [] }

    func setTrim(_ ms: Int64) {
        trimMs = min(max(ms, -Self.maxTrimMs), Self.maxTrimMs)
        prefs.set(trimMs, for: Self.keyTrimMs)
        session?.trimMs = trimMs
        EventLog.d("sync", "latency trim \(trimMs)ms")
    }

    /// Snapshot of the local player for the UI.
    func playerInfo() -> PlayerInfo {
        // After a restart the queue is back but nothing is loaded: show where the song will resume
        if roomCode == nil, let restored = local.restoredPositionMs {
            return PlayerInfo(playing: false, buffering: false, positionMs: restored, durationMs: local.snapshot.value.current?.durMs ?? 0)
        }
        var info = engine.playerInfo()
        info.heldBack = heldBack
        return info
    }

    /// Phase of the room as last announced by the server, or nil when not joined.
    func phase() -> String? { session?.snapshot.value.state?.phase }

    /// The app is going away: the room is kept in the prefs so that a restart soon after rejoins it.
    func release() {
        stopFollowing(deliberate: false)
        local.save()
        ownScope.cancel()
        scope.cancel()
        writer.sync {}
    }

    /// Stable per-install id, so a reconnecting device replaces its own stale socket.
    private func deviceId() -> String {
        if let id = prefs.string(Self.keyDeviceId) { return id }
        let id = UUID().uuidString
        prefs.set(id, for: Self.keyDeviceId)
        return id
    }

    private static func wallClockMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static let keyDeviceId = "device_id"
    private static let keyRoomCode = "room_code"
    private static let keyRoomName = "room_name"
    private static let keyAvatar = "avatar"
    /// The chat messages kept, as many as the room keeps.
    private static let chatKept = 100
    private static let keyRoomSolo = "room_solo"
    private static let keyRoomSoloItem = "room_solo_item"
    private static let keyLastActive = "room_last_active"
    private static let keyAutoplay = "autoplay"
    private static let keyVideo = "video_mode"
    private static let autoplayRestartAt = 150

    /// Songs added each time the queue runs out and the music carries on by itself.
    private static let autoplayCount = 5

    /// Songs that follow one that was played on its own.
    private static let radioCount = 20
    /// How often the radio looks whether the song it follows has loaded.
    private static let radioWaitStepMs: Int64 = 250
    private static let keyTrimMs = "trim_ms"
    private static let keyStartBiasMs = "start_bias_ms"
    private static let maxTrimMs: Int64 = 1000

    /// How often the time of the last sign of life is written down while in a room.
    private static let activeStampMs: Int64 = 60_000

    /// A room is rejoined after a restart only if this device was in it this recently.
    private static let recoveryWindowMs: Int64 = 10 * 60_000

    /// In a room, this long without sound or a look and the connection is let go of.
    private static let roomIdleMs: Int64 = 20 * 60_000
}

/// Writes a song into the listening history once it has been heard for long enough. It watches the player itself, so it
/// counts the same whether the song came from the personal queue or a room, and whether or not the screen is on.
@MainActor
final class ListenRecorder {
    private let engine: PlayerEngine
    private let time: TimeSource
    private let scope: Scope
    private let record: (TrackRef) -> Void
    private let recordSkip: (TrackRef) -> Void
    private var tracker: ListenTracker!

    /// The song being followed; kept whole so its details are not read from a player that has moved on.
    private var item: QueueItem?
    private var due: Job?

    init(engine: PlayerEngine, time: TimeSource, scope: Scope, record: @escaping (TrackRef) -> Void,
         recordSkip: @escaping (TrackRef) -> Void = { _ in }) {
        self.engine = engine
        self.time = time
        self.scope = scope
        self.record = record
        self.recordSkip = recordSkip
        tracker = ListenTracker(
            heard: { [weak self] id, durationMs in self?.heard(id, durationMs) },
            skipped: { [weak self] id, durationMs in self?.skipped(id, durationMs) }
        )
    }

    /// The player's state changed.
    func changed() {
        let next = engine.loadedItem
        let info = engine.playerInfo()
        // A song that ended and is loaded again (repeat one) is a new listen, so the end closes this one
        if next?.id != item?.id || next?.videoId != item?.videoId {
            // Counts the song that is ending, if it just passed the mark, so `item` still has to be that one
            tracker.begin(songId: next?.videoId, durationMs: info.durationMs, now: time.nowMs())
            item = next
        }
        if item != nil {
            tracker.setDuration(info.durationMs)
            tracker.setPlaying(info.playing, now: time.nowMs())
        }
        schedule()
    }

    private func schedule() {
        due?.cancel()
        due = nil
        guard let wait = tracker.msUntilHeard(time.nowMs()) else { return }
        due = scope.launch { [weak self] in
            guard let self, await self.time.wait(ms: wait) else { return }
            self.tracker.check(self.time.nowMs())
            self.schedule()
        }
    }

    /// The song was left after a few seconds: the suggestions learn not to offer more of it.
    private func skipped(_ id: String, _ durationMs: Int64) {
        guard let item, item.videoId == id else { return }
        EventLog.d("library", "skipped '\(item.title)'")
        recordSkip(TrackRef(videoId: id, title: item.title, artist: item.artist, thumb: item.thumb, durMs: durationMs))
    }

    private func heard(_ id: String, _ durationMs: Int64) {
        guard let item, item.videoId == id else { return }
        EventLog.d("library", "heard '\(item.title)'")
        record(TrackRef(videoId: id, title: item.title, artist: item.artist, thumb: item.thumb, durMs: durationMs))
    }
}
