import Foundation

/// What the player looks like from outside, for the screen.
struct PlayerInfo: Equatable {
    var playing = false
    var buffering = false
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var videoWidth = 0
    var videoHeight = 0
    /// The heights the picture of this song has, lowest first; empty when it plays without one.
    var videoLevels: [Int] = []
    /// The picture is wanted but this song plays without one.
    var noPicture = false
    /// Paused on this device while the room plays on, see `GroupController.heldBack`.
    var heldBack = false
    /// How fast the player plays: the person's choice outside a room, the drift control's in one.
    var speed: Float = 1
    /// Codec, average bitrate and sample rate of the audio stream currently playing; nil until known.
    var audioFormat: AudioFormat? = nil
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

    /// The six bands of the equalizer in whole dB (see `Eq`); applied to what plays and to what comes after.
    func setEqualizer(_ gains: [Int])

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

    /// The tallest picture asked for changed (`maxVideoHeight`, or the network became metered): the song that plays goes to
    /// the new height with the sound going on.
    func videoQualityChanged()

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
    func videoQualityChanged() {}
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
        /// This device has the secret of the room's end-to-end encrypted chat.
        var sealedKey = false
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
    private let moreLike: (_ seeds: [String], Set<String>, Int) async throws -> [TrackRef]
    private let tasteOffer: () async throws -> [TrackRef]
    /// Runs the work it is given in a way that lets it finish when the app goes to the background (on iPhone, in a
    /// background task), so the song after the last is not left unfetched. Plain runs the work, where there is no need.
    private let awake: (@escaping () async -> Void) async -> Void
    /// The secrets of the rooms with end-to-end encrypted chat.
    let secrets: RoomSecretStore
    /// Send what plays to ListenBrainz and to Last.fm when the person connected them; nil where there is nowhere to keep a token.
    let scrobbler: Scrobbler?
    let lastFm: Scrobbler?
    let lastFmService: LastFmService?
    private let sockets: SocketFactory?
    private let clock = ClockSync()
    private let writer = DispatchQueue(label: "sapoche.queue-writer")

    /// Lives as long as this controller; [scope] is replaced each time a room is left.
    private let ownScope = Scope()
    private var scope = Scope()

    /// The queue that plays outside a room; it comes back after a restart, paused.
    private(set) var local: LocalSession!

    /// What is known about the network, whether listening in a room or alone: it decides the quality songs are fetched in.
    private let health = NetworkHealth()

    /// Stops this device after a while, or when the song is over; the fade is the player's own volume.
    private(set) var sleep: SleepTimer!

    private var client: RoomClient?
    private var session: GroupSession?
    /// Which songs of the queue autoplay or a shelf put there, so a listen can say where it came from.
    private let sources = ListenSources()

    /// Where the queue item now playing came from; see `ListenSource`.
    func listenSource(_ item: QueueItem) -> String {
        guard let session else { return sources.of(item.videoId) }
        return sources.of(item.videoId, item: item, you: session.snapshot.value.you)
    }

    /// The song that was just left was skipped by another member of the room, not by this device.
    func leftByOther() -> Bool {
        guard let session else { return false }
        return !session.isSolo && session.changedByOther
    }

    private var autoplayJob: Job?
    private var radioJob: Job?

    /// The job that looks for songs for the room, and the epoch of the question it answers; see `fillRoom`.
    private var fillJob: Job?
    private var fillEpoch: Int64?

    /// Songs found for the room that could not be sent because the connection was down; sent when it is back and the
    /// room is still waiting for them.
    private var owedFill: OwedFill?

    private struct OwedFill {
        let epoch: Int64
        let songs: [TrackRef]
        let title: String
    }

    /// Holds the app awake in the background while the room, run out of songs, waits for the next to start.
    private var idleHold: Job?
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

    /// Callers of `mediaTickets` waiting for the room's answer, by the id of their request.
    private var ticketWaiters: [String: CheckedContinuation<[String: Any], Never>] = [:]

    func picturesSeen() -> [Avatar] {
        pictures.map { Avatar(id: $0.key, data: $0.value) }
    }

    /// Chat messages of room [room]: all it keeps when [replace], else new ones to add or ones that changed. [receipts] is
    /// what each member has got of the chat when that changed (or came with everything), else nil. [older]: a page of
    /// messages from before the ones shown, asked for with `loadOlderChat`. [more]: the room keeps messages from before
    /// the oldest shown (nil when this says nothing about it).
    struct Chat: Equatable {
        let room: String
        let messages: [ChatMessage]
        let replace: Bool
        var receipts: [String: ChatReceipt]?
        var older = false
        var more: Bool?
    }

    let chat = SharedFlow<Chat>()

    /// What the person is to be told of the chat; whether it is shown depends on whether they are looking at the app.
    let chatNotices = SharedFlow<ChatNotice>()

    /// The room's chat as last heard; nil until the room sent its history (a server older than protocol 10 never does).
    private var chatLog: [ChatMessage]?

    /// What each member has got of the chat, as the room last said.
    private var receiptsLog: [String: ChatReceipt] = [:]

    /// The last message this device told the room it has, so that it says so once for each.
    private var deliveredUpTo: Int64 = 0

    /// Whether the room kept messages from before `chatLog`, as it said last.
    private var chatMore = false

    /// Asks the room for the messages older than number [before]; false when there is no connection to ask on.
    func loadOlderChat(before: Int64) -> Bool { client?.send(Wire.chatBefore(before)) ?? false }

    /// The whole chat, for a screen that comes back after messages arrived.
    func chatSeen() -> Chat? {
        guard let roomCode, let chatLog else { return nil }
        return Chat(room: roomCode, messages: open(roomCode, chatLog), replace: true, receipts: receiptsLog, more: chatMore)
    }

    /// [messages] as the room sent them, with the words of sealed ones read when this device has the room's secret.
    private func open(_ room: String, _ messages: [ChatMessage]) -> [ChatMessage] { messages.map { open(room, $0) } }

    private func open(_ room: String, _ message: ChatMessage) -> ChatMessage {
        guard message.ct != nil else { return message }
        if let secret = secrets.secret(for: room), let opened = ChatCipher.openMessage(secret: secret, room: room, message: message) { return opened }
        var locked = message
        locked.text = ""
        locked.re = nil
        locked.locked = true
        return locked
    }

    /// A secret for room [code] came (from an invitation link, or this device made it): the chat is shown again, now that
    /// it can be read.
    func roomSecretChanged(_ code: String) {
        guard code.uppercased() == roomCode else { return }
        publish()
        if let seen = chatSeen() { chat.emit(seen) }
    }

    /// Turns on end-to-end encryption in the room this device owns: a new secret is made and kept here, and the room is
    /// told, which deletes the chat so far. The secret is then to be given to the others, with `roomSecret`. False when
    /// this device is not in a room it owns, or the room is sealed already.
    func enableEncryption() -> Bool {
        guard let code = roomCode, let snapshot = session?.snapshot.value else { return false }
        if snapshot.state?.enc == true || snapshot.state?.ownerId != snapshot.you { return false }
        secrets.save(ChatCipher.newSecret(), for: code)
        publish()
        return send(Wire.roomEncrypt())
    }

    /// The secret of the room this device is in, as written in an invitation link; nil when it has none.
    func roomSecret() -> String? {
        guard let roomCode, let secret = secrets.secret(for: roomCode) else { return nil }
        return ChatCipher.encodeSecret(secret)
    }

    /// Member [by] reacted with [e], [n] taps of it.
    struct Reaction: Equatable {
        let by: String
        let e: String
        let n: Int
    }

    let reactions = SharedFlow<Reaction>()

    /// Sends a chat message, as an answer to message number [reply] when it has one; false when there is no connection to send it on.
    func sendChat(_ text: String, cid: String, reply: Int64? = nil, quote: ChatQuote? = nil, extra: [String: Any]? = nil) -> Bool {
        guard let client, let code = roomCode else { return false }
        let snapshot = session?.snapshot.value
        if snapshot?.state?.enc != true { return client.send(Wire.chat(text, cid: cid, reply: reply, x: extra)) }
        // A sealed room: the words go sealed, with what they answer and what they carry inside; without the secret there is nothing to send
        guard let secret = secrets.secret(for: code), let you = snapshot?.you,
              let sealed = ChatCipher.sealMessage(secret: secret, room: code, by: you, text: text, quote: quote, x: extra) else { return false }
        return client.send(Wire.chatSealed(ct: sealed.ct, pv: sealed.pv, cid: cid, reply: reply))
    }

    /// Gives chat message [id] this device's reaction [e] (a name of the room's reactions or an emoji); nil takes it away.
    func reactToChat(_ id: Int64, _ e: String?) { client?.send(Wire.chatReact(id, e)) }

    /// The chat is on a screen, and its messages up to number [upTo] have been looked at.
    func readChat(upTo: Int64) { client?.send(Wire.chatReceipt(read: upTo)) }

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
         recordListen: @escaping (TrackRef, String) -> Void = { _, _ in }, recordSkip: @escaping (TrackRef, String) -> Void = { _, _ in },
         time: TimeSource? = nil, sockets: SocketFactory? = nil,
         moreLike: @escaping ([String], Set<String>, Int) async throws -> [TrackRef] = { _, _, _ in [] },
         tasteOffer: @escaping () async throws -> [TrackRef] = { [] },
         secrets: RoomSecretStore = MemorySecrets(),
         scrobbler: Scrobbler? = nil, lastFm: Scrobbler? = nil, lastFmService: LastFmService? = nil,
         awake: @escaping (@escaping () async -> Void) async -> Void = { await $0() }) {
        self.engine = engine
        self.secrets = secrets
        self.scrobbler = scrobbler
        self.lastFm = lastFm
        self.lastFmService = lastFmService
        self.prefs = prefs
        self.queueFile = queueFile
        self.config = config
        self.time = time ?? SystemTime.shared
        self.sockets = sockets
        self.moreLike = moreLike
        self.tasteOffer = tasteOffer
        self.awake = awake
        trimMs = prefs.int64(Self.keyTrimMs) ?? 0
        videoMode = prefs.bool(Self.keyVideo, default: false)
        view = StateFlow(View())
        engine.setEqualizer(Self.storedEqGains(prefs))

        health.onChange = { weak in
            NetworkState.shared.weak = weak
            if weak { EventLog.w("net", "weak network: the room may run ahead") } else { EventLog.k("net", "network is good again") }
        }
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
            time: self.time,
            health: health
        )
        sleep = SleepTimer(
            scope: ownScope,
            time: self.time,
            wallClock: { Int64(Date().timeIntervalSince1970 * 1000) },
            stop: { [weak self] in self?.stopForSleep() },
            fade: { [weak self] in self?.fadeVolume($0) },
            pauseAtSongEnd: { [weak engine] in engine?.setPauseAtSongEnd($0) }
        )
        recorder = ListenRecorder(
            engine: engine, time: self.time, scope: ownScope, record: recordListen, recordSkip: recordSkip,
            sourceOf: { [weak self] in self?.listenSource($0) ?? ListenSource.chosen },
            leftByOther: { [weak self] in self?.leftByOther() ?? false },
            scrobblers: [scrobbler, lastFm].compactMap { $0 }
        )
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
            self.applyVolume()
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
        set {
            prefs.set(newValue, for: Self.keyAutoplay)
            // Turned on when the queue had already run out: it carries on now, not at the end of the next queue
            if newValue, session == nil, local.snapshot.value.finished, let last = local.snapshot.value.queue.last { autoplay(after: last) }
        }
    }

    /// The personal queue ran out. Unless the person turned it off, it carries on with songs like the last one, so the
    /// music does not just stop. Nothing happens without a network, in a room, or when they asked for something else in
    /// the meantime.
    private func autoplay(after last: QueueItem, retryOfDebt: Bool = false) {
        owedAutoplay = nil
        if !autoplayOn || session != nil || autoplayJob?.isActive == true || sleep.state.value == .songEnd { return }
        // A song from a file on this phone has no radio: the last song from YouTube in the queue stands in for it
        let like = LocalMusic.isLocal(last.videoId) ? local.snapshot.value.queue.last { !LocalMusic.isLocal($0.videoId) } : last
        guard let like else { return }
        autoplayJob = ownScope.launch { [weak self] in
            guard let self else { return }
            // Still wanted: the person did not turn it off, join a room or ask for something else while the songs are looked for
            let wanted = { [weak self] () -> Bool in
                guard let self else { return false }
                return self.autoplayOn && self.session == nil && self.local.snapshot.value.finished && self.sleep.state.value != .songEnd
            }
            await self.awake { [weak self] in
                guard let self else { return }
                do {
                    let more = try await Queues.retrying(
                        time: self.time,
                        stillWanted: wanted,
                        missed: { n, error in EventLog.d("local", "autoplay try #\(n) found nothing\(error.map { ": \($0.localizedDescription)" } ?? "")") }
                    ) {
                        let queued = Set(self.local.snapshot.value.queue.map(\.videoId))
                        return try await self.moreLike([like.videoId], queued, Self.autoplayCount)
                    }
                    if more.isEmpty || !wanted() {
                        // Nothing found though still wanted: one more round when the network comes back, if that is soon
                        if more.isEmpty, wanted(), !retryOfDebt {
                            self.owedAutoplay = (like, self.time.nowMs())
                            EventLog.d("local", "autoplay owes one more try when the network is back, for \(Self.autoplayOwedMs / 60_000) minutes")
                        }
                        return
                    }
                    EventLog.d("local", "autoplay adds \(more.count) songs like '\(like.title)'")
                    // Carrying on only adds: what has been played makes room when the new songs would not fit
                    self.local.dropPlayed(self.local.snapshot.value.queue.count + more.count - LocalSession.maxQueue)
                    self.sources.mark(more.map(\.videoId), source: ListenSource.auto)
                    self.local.add(more, next: false, queued: false, auto: true)
                } catch is CancellationError {
                    return
                } catch {
                    EventLog.d("local", "autoplay found nothing: \(error.localizedDescription)")
                }
            }
        }
    }

    /// All the tries of `autoplay` found nothing and the music is at a stop: the song it looked for songs like, and when
    /// it gave up. When the network changes or comes back within `autoplayOwedMs`, one more round is made; later the music
    /// starting by itself would only be a surprise.
    private var owedAutoplay: (like: QueueItem, since: Int64)?

    private func retryOwedAutoplay() {
        guard let owed = owedAutoplay else { return }
        owedAutoplay = nil
        if time.nowMs() - owed.since > Self.autoplayOwedMs {
            EventLog.d("local", "autoplay owes nothing any more: it is too late now")
            return
        }
        EventLog.d("local", "autoplay owes nothing any more: the network is back")
        autoplay(after: owed.like, retryOfDebt: true)
    }

    /// The room's queue ran out and the server asked this device for songs like the last one, as `autoplay` does for the
    /// personal queue. The search is tried again when it finds nothing, and the same question twice (the server puts it
    /// again when a device comes in) does not start a second search. Nothing is sent when the room has moved on by the
    /// time the songs arrive; songs found while the connection was down are sent when it is back (see `deliverOwedFill`).
    private func fillRoom(epoch: Int64, videoId: String, title: String, tastes: [MemberTaste]) {
        if fillJob?.isActive == true {
            if fillEpoch == epoch {
                EventLog.d("sync", "autoplay is asked again for epoch \(epoch), it is already looking")
                return
            }
            fillJob?.cancel()
        }
        if owedFill?.epoch == epoch, deliverOwedFill(session?.snapshot.value.state) { return }
        owedFill = nil
        fillEpoch = epoch
        fillJob = scope.launch { [weak self] in
            guard let self else { return }
            let wanted = { [weak self] () -> Bool in
                guard let self else { return false }
                return Self.roomWaits(for: epoch, self.session?.snapshot.value.state)
            }
            await self.awake { [weak self] in
                guard let self else { return }
                do {
                    // The songs of the queue, and a song of each member who offered some, going round with each time the room runs out
                    let seeds = Queues.blend(Queues.seeds(self.queue(), ask: videoId), offers: self.openOffers(tastes), epoch: epoch)
                    let more = try await Queues.retrying(
                        time: self.time,
                        stillWanted: wanted,
                        missed: { n, error in EventLog.d("sync", "autoplay try #\(n) found nothing for the room\(error.map { ": \($0.localizedDescription)" } ?? "")") }
                    ) {
                        try await self.moreLike(seeds, Set(self.queue().map(\.videoId)), Self.autoplayCount)
                    }
                    if more.isEmpty {
                        EventLog.d("sync", wanted() ? "autoplay found nothing for the room, the room asks another device" : "autoplay found nothing and the room had moved on")
                        return
                    }
                    if !wanted() {
                        EventLog.d("sync", "autoplay found \(more.count) songs but the room had moved on")
                        return
                    }
                    EventLog.d("sync", "autoplay found \(more.count) songs like '\(title)' and \(seeds.count - 1) more for the room")
                    if !self.sendFill(more) {
                        self.owedFill = OwedFill(epoch: epoch, songs: more, title: title)
                        EventLog.d("sync", "fill owed: the room cannot be reached, the songs are kept until it can")
                    }
                } catch is CancellationError {
                    return
                } catch {
                    EventLog.d("sync", "autoplay found nothing for the room: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Marked as autoplay's, so the room keeps them apart from the songs its members chose. Whether it could be sent.
    private func sendFill(_ songs: [TrackRef]) -> Bool { send(Wire.queueAddMany(songs, auto: true)) }

    /// The room is idle at [epoch] and still asks for songs: the answer to its question can still be used.
    private static func roomWaits(for epoch: Int64, _ state: RoomState?) -> Bool {
        guard let state else { return false }
        return state.epoch == epoch && state.phase == "idle" && state.autoplay != false
    }

    /// A [state] of the room came: songs `owedFill` kept are sent if the room still waits for them. Whether anything was sent.
    @discardableResult
    private func deliverOwedFill(_ state: RoomState?) -> Bool {
        guard let owed = owedFill else { return false }
        owedFill = nil // sent or not, an answer is given once
        if !Self.roomWaits(for: owed.epoch, state) {
            EventLog.d("sync", "fill owed: the room had moved on, the songs are dropped")
            return false
        }
        let sent = sendFill(owed.songs)
        EventLog.d("sync", "fill owed: \(owed.songs.count) songs like '\(owed.title)' \(sent ? "sent now" : "could not be sent")")
        return sent
    }

    /// The room sent its [state]: pays what is owed, and keeps the app awake in the background while a room that ran out
    /// of songs and carries on by itself waits for the next to start.
    private func roomStateCame(_ state: RoomState) {
        if owedFill != nil, fillJob?.isActive != true { deliverOwedFill(state) }
        if state.phase == "playing" {
            idleHold?.cancel()
        } else if state.phase == "idle", state.autoplay == true, !state.queue.isEmpty, idleHold?.isActive != true,
                  !engine.wantsSound, sleep.state.value != .songEnd {
            idleHold = scope.launch { [weak self] in
                guard let self else { return }
                await self.awake { [weak self] in
                    guard let self else { return }
                    EventLog.d("awake", "holding the app awake for the room that ran out of songs, at most \(Self.idleHoldMs / 1000) s")
                    _ = await self.time.wait(ms: Self.idleHoldMs)
                }
            }
        }
    }

    /// Whether this device offers the songs it loves to a room's autoplay (on unless the person turned it off).
    var shareTasteOn: Bool {
        get { prefs.bool(Self.keyShareTaste, default: true) }
        set {
            prefs.set(newValue, for: Self.keyShareTaste)
            shareTaste()
        }
    }

    /// The message last sent about this device's songs on this connection, so the same one is not sent again at every state.
    private var sentTaste: String?
    private var tasteJob: Job?

    /// What this person loves changed (a song was heard, a mark put on the taste): tells the room soon, if it differs.
    func tasteChanged() {
        if session == nil { return }
        tasteJob?.cancel()
        tasteJob = scope.launch { [weak self] in
            guard let self else { return }
            try await self.time.sleep(ms: Self.tasteDelayMs)
            self.shareTaste()
        }
    }

    /// Hands the room the songs this device offers autoplay, or takes them back when the person does not want to share, once
    /// per connection and again when they change. A room whose chat is sealed is given them sealed, and without its secret
    /// nothing can be offered. The server must know protocol 19.
    private func shareTaste() {
        guard let session else { return }
        scope.launch { [weak self] in
            // Read once the session has taken in the state that came with this
            guard let self, let state = session.snapshot.value.state, let code = self.roomCode, let you = session.snapshot.value.you else { return }
            let sealed = state.enc
            var offer: [TasteSeed] = []
            if self.shareTasteOn {
                do {
                    offer = try await self.tasteOffer().map { TasteSeed(v: $0.videoId, ti: String($0.title.prefix(Self.tasteText)), ar: String($0.artist.prefix(Self.tasteText))) }
                } catch {
                    return
                }
            }
            let message: String
            if offer.isEmpty {
                message = sealed ? Wire.tasteSetSealed(nil) : Wire.tasteSet(nil)
            } else if !sealed {
                message = Wire.tasteSet(offer)
            } else if let secret = self.secrets.secret(for: code), let envelope = ChatCipher.sealTaste(secret: secret, room: code, by: you, seeds: offer) {
                message = Wire.tasteSetSealed(envelope)
            } else {
                message = Wire.tasteSetSealed(nil)
            }
            if message == self.sentTaste || self.session !== session { return }
            if self.send(message) { self.sentTaste = message }
        }
    }

    /// The video ids each member offered in [tastes], opened with the room's secret when the chat is sealed; a member whose
    /// offer cannot be read is left out.
    private func openOffers(_ tastes: [MemberTaste]) -> [[String]] {
        guard let code = roomCode else { return [] }
        let secret = session?.snapshot.value.state?.enc == true ? secrets.secret(for: code) : nil
        return tastes.map { member in
            let seeds = member.seeds ?? member.s.flatMap { sealed in secret.flatMap { ChatCipher.openTaste(secret: $0, room: code, by: member.by, envelope: sealed) } }
            return (seeds ?? []).map(\.v)
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
                let more = try await self.moreLike([videoId], [videoId], Self.radioCount)
                let snap = self.local.snapshot.value
                let contextOnly = snap.queue.filter { !snap.queued.contains($0.id) }
                if more.isEmpty || self.session != nil || contextOnly.count != 1 || contextOnly[0].videoId != videoId { return }
                EventLog.d("local", "radio adds \(more.count) songs like \(videoId)")
                self.sources.mark(more.map(\.videoId), source: ListenSource.auto)
                self.local.add(more, next: false, queued: false)
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
    func setVideoVisible(_ visible: Bool) {
        pictureVisible = visible
        engine.setVideoVisible(visible)
        applyVolume()
    }

    /// The tallest picture asked for changed.
    func videoQualityChanged() { engine.videoQualityChanged() }

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
                                      send: { [weak self] text in self?.client?.send(text) }, log: log, health: health)
        newSession.trimMs = trimMs
        newSession.startBiasMs = prefs.int64(Self.keyStartBiasMs) ?? 0
        newSession.onStartBiasLearned = { [weak self] in self?.prefs.set($0, for: Self.keyStartBiasMs) }
        let newClient = RoomClient(baseUrl: settings.server, roomCode: code, clientId: id, name: name, scope: scope, clock: clock,
                                   time: time, log: log, headers: settings.authHeaders, create: create, sockets: sockets,
                                   appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        newClient.onMessage = { [weak self] message in
            if case let .error(code, text) = message { self?.errors.emit(ControllerError(code: code, message: text)) }
            if case let .autoplayFill(epoch, videoId, title, tastes) = message { self?.fillRoom(epoch: epoch, videoId: videoId, title: title, tastes: tastes) }
            if case let .state(_, _, state, _, _) = message { self?.roomStateCame(state) }
            if case let .mediaTicket(id, tickets) = message, let id {
                self?.answerTickets(id, ["tickets": tickets.map { ["m": $0.m, "url": $0.url, "token": $0.token] }])
            }
            // An error of the pictures is the answer to the one request that waits for it
            if case let .error(code, _) = message, code.hasPrefix("media_"), let waiting = self?.ticketWaiters.keys.first {
                self?.answerTickets(waiting, ["error": code])
            }
            self?.onChat(room: code.uppercased(), message)
            newSession.onMessage(message)
            // After the session has the state: the offer depends on whether the room's chat is sealed
            if case let .state(_, _, _, _, protocolVersion) = message, protocolVersion >= Self.tasteProtocol { self?.shareTaste() }
        }
        newClient.onAvatar = { [weak self] memberId, _, received, sealed in
            guard let self else { return }
            // The picture behind a sealed chat is opened here, so the screen gets a JPEG as ever; without the secret there is none
            let data = !sealed || received == nil ? received : self.openBackground(code, received ?? "")
            self.pictures[memberId] = data
            self.avatars.emit(Avatar(id: memberId, data: data))
        }
        newClient.setAvatar(prefs.string(Self.keyAvatar))
        newClient.onConnected = { [weak self, weak newClient] in
            self?.sentTaste = nil
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
            case let .waiting(byId): self.notices.emit(Notice(kind: "waiting", by: nameOf(byId)))
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
        retryOwedAutoplay()
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
        chatMore = false
        receiptsLog = [:]
        deliveredUpTo = 0
        scope.cancel()
        scope = Scope()
        fillJob = nil
        fillEpoch = nil
        owedFill = nil
        idleHold = nil
        local.attach() // the personal queue gets the player back, paused where it was
        publish()
        updateIdle()
    }

    /// Tells the room that the chat has reached this device up to [last], so that the others can see their message as
    /// delivered. The screen need not be on: this is the device having it, not the person having read it.
    private func acknowledge(_ last: ChatMessage) {
        if last.id <= deliveredUpTo { return }
        deliveredUpTo = last.id
        // What this device wrote itself needs no word
        if last.by != session?.snapshot.value.you { client?.send(Wire.chatReceipt(delivered: last.id)) }
    }

    private func onChat(room: String, _ message: ServerMessage) {
        switch message {
        case let .chatHistory(messages, receipts, more):
            let kept = Array(messages.suffix(Self.chatKept))
            chatLog = kept
            chatMore = more
            receiptsLog = receipts
            chat.emit(Chat(room: room, messages: open(room, kept), replace: true, receipts: receipts, more: more))
            if let last = kept.last { acknowledge(last) }
        case let .chatPage(_, messages, more):
            // Not kept here: the screen holds the pages it asked for, and the log is only what a returning screen is given
            chat.emit(Chat(room: room, messages: open(room, messages), replace: false, older: true, more: more))
        case let .chat(message):
            let opened = open(room, message)
            // What cannot be read has no words to tell
            if !opened.locked, let notice = ChatNotices.forMessage(opened, room: room, you: session?.snapshot.value.you) { chatNotices.emit(notice) }
            chatLog = Array(((chatLog ?? []) + [message]).suffix(Self.chatKept))
            chat.emit(Chat(room: room, messages: [opened], replace: false))
            acknowledge(message)
        case let .chatUpdate(message):
            guard let log = chatLog else { return }
            let snapshot = session?.snapshot.value
            // A message from further back than the log has no earlier version here to tell what is new in it
            let opened = open(room, message)
            if !opened.locked, let before = log.first(where: { $0.id == message.id }),
               let notice = ChatNotices.forUpdate(before: before, after: opened, room: room, you: snapshot?.you,
                                                  nameOf: { who in snapshot?.members.first { $0.id == who }?.name }) {
                chatNotices.emit(notice)
            }
            chatLog = log.map { $0.id == message.id ? message : $0 }
            chat.emit(Chat(room: room, messages: [opened], replace: false))
        case let .chatReceipts(receipts):
            receiptsLog = receipts
            chat.emit(Chat(room: room, messages: [], replace: false, receipts: receipts))
        case let .react(by, e, n):
            reactions.emit(Reaction(by: by, e: e, n: n))
        default:
            break
        }
    }

    private func publish() {
        view.set(View(roomCode: roomCode, connection: client?.connection.value,
                      snapshot: session?.snapshot.value ?? GroupSession.Snapshot(), local: local.snapshot.value,
                      sealedKey: roomCode.map { secrets.secret(for: $0) != nil } ?? false))
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
    @discardableResult func requestClearQueued() -> Bool { onQueue({ $0.clearQueued() }) { false } }
    @discardableResult func requestShuffle() -> Bool { onQueue({ $0.shuffle() }) { send(Wire.queueShuffle()) } }
    /// Shuffle as a mode. A server older than protocol 11 has none, so there it mixes the queue once, as it always did.
    @discardableResult func requestShuffleMode(_ on: Bool) -> Bool {
        onQueue({ $0.setShuffle(on) }) {
            if session?.snapshot.value.state?.shuffle == nil { return on ? send(Wire.queueShuffle()) : true }
            return send(Wire.shuffle(on))
        }
    }
    @discardableResult func requestRepeat(_ mode: String) -> Bool { onQueue({ $0.setRepeat(mode) }) { send(Wire.repeatMode(mode)) } }
    @discardableResult func requestAddMany(_ tracks: [TrackRef], playNext: Bool, source: String = ListenSource.chosen, queued: Bool = true) -> Bool {
        sources.mark(tracks.map(\.videoId), source: source)
        return onQueue({ $0.add(tracks, next: playNext, queued: queued) }) {
            // What is waiting in the room's queue is not added twice
            let fresh = Queues.fresh(tracks, queue: queue(), index: session?.snapshot.value.state?.index ?? 0)
            return fresh.isEmpty || send(Wire.queueAddMany(fresh, playNext: playNext))
        }
    }
    /// The personal queue as another device of this person can take it over (Connect), as `{"dropped":n,"saved":{...}}`; nil in a
    /// room, whose queue is everybody's. The songs of this device's own music are left out and counted.
    func exportQueueJson() -> String? {
        if session != nil { return nil }
        let handover = local.exportQueue()
        guard let data = try? JSONEncoder().encode(handover.saved), let saved = String(data: data, encoding: .utf8) else { return nil }
        return "{\"dropped\":\(handover.dropped),\"saved\":\(saved)}"
    }

    /// Takes the JSON of a queue `exportQueueJson` made on another device as the personal queue; false in a room or when it is not one.
    func importQueueJson(_ json: String, play: Bool) -> Bool {
        if session != nil { return false }
        guard let saved = try? JSONDecoder().decode(SavedQueue.self, from: Data(json.utf8)) else { return false }
        local.importQueue(saved, play: play)
        return true
    }

    /// Outside a room [tracks] become the queue and play from song [start]; a room's queue is shared, so they are only added to it.
    @discardableResult func requestPlayList(_ tracks: [TrackRef], start: Int, label: String? = nil, source: String = ListenSource.chosen) -> Bool {
        sources.mark(tracks.map(\.videoId), source: source)
        return onQueue({ $0.playList(tracks, start: start, label: label) }) {
            let fresh = Queues.fresh(tracks, queue: queue(), index: session?.snapshot.value.state?.index ?? 0)
            return fresh.isEmpty || send(Wire.queueAddMany(fresh, playNext: false))
        }
    }
    /// Plays [track], another release of the song, in place of the queue item [itemId]. What is playing carries on while
    /// the new release is made ready, so that the sound is cut only for the time the first of its data takes, not for all
    /// of the lookup as well.
    @discardableResult func requestSwap(_ itemId: String, _ track: TrackRef) -> Bool {
        let withVideo = videoMode
        Task {
            await engine.warm(track.videoId, withVideo: withVideo)
            onQueue({ $0.swap(itemId, track) }) { send(Wire.queueSwap(itemId, track)) }
        }
        return true
    }
    @discardableResult func requestRemove(_ itemId: String) -> Bool { onQueue({ $0.remove(itemId) }) { send(Wire.queueRemove(itemId)) } }
    @discardableResult func requestMove(_ itemId: String, _ toIndex: Int, queued: Bool? = nil) -> Bool { onQueue({ $0.move(itemId, toIndex: toIndex, queued: queued) }) { send(Wire.queueMove(itemId, toIndex: toIndex)) } }

    // Only meaningful in a room
    @discardableResult func requestKick(_ memberId: String) -> Bool { send(Wire.kick(memberId)) }
    @discardableResult func requestRoomName(_ name: String) -> Bool { send(Wire.roomName(name)) }
    @discardableResult func requestRoomTheme(_ theme: String, bg: String?) -> Bool {
        guard let code = roomCode else { return false }
        if session?.snapshot.value.state?.enc != true { return send(Wire.roomTheme(theme, bg: bg)) }
        // A sealed room keeps the picture sealed: without the secret there is nothing to send, and a clear one is not taken
        guard let secret = secrets.secret(for: code) else { return false }
        var sealed: String?
        if let bg {
            guard let jpeg = Data(base64Encoded: bg), let envelope = ChatCipher.sealBackground(secret: secret, room: code, jpeg: jpeg) else { return false }
            sealed = envelope
        }
        return send(Wire.roomTheme(theme, bg: sealed, sealed: true))
    }

    /// Tickets for files of [sizes] bytes, or the code of the error the room answered with (`media_full`, ...) or `offline`.
    func mediaTickets(sizes: [Int64]) async -> [String: Any] {
        guard let client else { return ["error": "offline"] }
        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            ticketWaiters[id] = continuation
            if !client.send(Wire.mediaPut(sizes, id: id)) {
                answerTickets(id, ["error": "offline"])
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: Self.ticketWaitMs * 1_000_000)
                answerTickets(id, ["error": "offline"])
            }
        }
    }

    private func answerTickets(_ id: String, _ answer: [String: Any]) { ticketWaiters.removeValue(forKey: id)?.resume(returning: answer) }

    /// The picture behind a sealed chat opened with the secret of [room]; nil without it.
    private func openBackground(_ room: String, _ envelope: String) -> String? {
        guard let secret = secrets.secret(for: room) else { return nil }
        return ChatCipher.openBackground(secret: secret, room: room, envelope: envelope)?.base64EncodedString()
    }
    @discardableResult func requestRoomSettings(_ guestControl: String) -> Bool { send(Wire.roomSettings(guestControl: guestControl)) }
    @discardableResult func requestRoomAutoplay(_ on: Bool) -> Bool { send(Wire.autoplay(on)) }
    @discardableResult func requestRoomWaitWeak(_ on: Bool) -> Bool { send(Wire.waitWeak(on)) }

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

    // ------------------------------------------------------------------ volume

    /// Songs are played at the same loudness (see [Loudness]) unless the person turned that off.
    var normalizeVolumeOn: Bool {
        get { prefs.bool(Self.keyNormalizeVolume, default: true) }
        set {
            prefs.set(newValue, for: Self.keyNormalizeVolume)
            applyVolume()
        }
    }

    /// Where the loudness of a song is found when this run has not heard of it yet (kept from an earlier listen).
    var loudnessLookup: (@Sendable (String) async -> Double?)?

    /// How loud [videoId] is, from a stream of it. Applied at once when it is the song that is loaded.
    func loudnessLearned(_ videoId: String, _ db: Double) {
        loudness[videoId] = db
        if engine.loadedItem?.videoId == videoId { applyVolume() }
    }

    /// The sleep timer's fade: the share (1 is full) of the volume that the loudness of the song allows.
    private func fadeVolume(_ share: Float) {
        fade = share
        applyVolume()
    }

    /// The seconds of the soft change between songs (see [Crossfade]), 0 for none; the person's choice.
    var crossfadeSeconds: Int {
        get { min(max(Int(prefs.int64(Self.keyCrossfade, default: 0)), 0), Crossfade.maxSeconds) }
        set {
            prefs.set(Int64(min(max(newValue, 0), Crossfade.maxSeconds)), for: Self.keyCrossfade)
            applyVolume()
        }
    }

    /// The name of the preset the equalizer was set from, for the screen to show; the person's own choice.
    var equalizerPreset: String { prefs.string(Self.keyEqPreset) ?? "off" }

    /// The six bands of the equalizer in whole dB.
    var equalizerGains: [Int] { Self.storedEqGains(prefs) }

    /// The equalizer of this device: kept, and applied at once. It is not shared with a room.
    func setEqualizer(preset: String, gains: [Int]) {
        let clean = Eq.clean(gains.map(Double.init))
        prefs.set(preset, for: Self.keyEqPreset)
        prefs.set(clean.map(String.init).joined(separator: ","), for: Self.keyEqGains)
        engine.setEqualizer(clean)
    }

    private static func storedEqGains(_ prefs: KeyValueStore) -> [Int] {
        Eq.clean(prefs.string(keyEqGains)?.split(separator: ",").compactMap { Double($0) })
    }

    /// What the song that plays was like when the soft change last looked at it.
    private struct Seen {
        let id: String
        let positionMs: Int64
        let durationMs: Int64
        let playing: Bool
        let atMs: Int64
    }

    private var seen: Seen?

    /// The song that plays came by itself, so it fades in; one that was chosen starts as it is.
    private var startedByItself = false
    private var crossfadeJob: Job?
    private var pictureVisible = false

    /// The share of the volume the soft change allows at the position of the song that plays.
    private func crossfadeRamp() -> Float {
        let seconds = crossfadeSeconds
        guard seconds > 0 else {
            seen = nil
            return 1
        }
        guard let item = engine.loadedItem else { return 1 }
        let info = engine.playerInfo()
        let now = time.nowMs()
        let duration = item.durMs > 0 ? item.durMs : info.durationMs
        if let before = seen, before.id != item.id {
            // Neither the engine nor the sessions say how a song was left; the one that played to its end is known by where it was
            startedByItself = before.playing && Crossfade.endedItself(
                lastPositionMs: before.positionMs, durationMs: before.durationMs, elapsedMs: now - before.atMs)
        }
        seen = Seen(id: item.id, positionMs: info.positionMs, durationMs: duration, playing: info.playing, atMs: now)
        if videoMode && pictureVisible { return 1 }
        return Crossfade.ramp(
            positionMs: info.positionMs, durationMs: duration, seconds: seconds, fadeIn: startedByItself, fadeOut: hasSuccessor)
    }

    private var hasSuccessor: Bool { session?.hasSuccessor ?? local.hasSuccessor }

    /// Runs the clock only while a soft change is on: 30 times a second inside it, and once at the moment the end of the
    /// song gets to it. Outside, nothing runs.
    private func scheduleCrossfadeTick() {
        crossfadeJob?.cancel()
        crossfadeJob = nil
        let seconds = crossfadeSeconds
        guard seconds > 0, let seen, seen.playing, !(videoMode && pictureVisible),
              Crossfade.applies(durationMs: seen.durationMs, seconds: seconds) else { return }
        let outAt = seen.durationMs - Int64(seconds) * 1000
        let delay: Int64
        if startedByItself && seen.positionMs < Int64(seconds) * 500 {
            delay = Self.crossfadeTickMs
        } else if !hasSuccessor {
            return
        } else if seen.positionMs >= outAt {
            delay = Self.crossfadeTickMs
        } else {
            delay = max(outAt - seen.positionMs, 1)
        }
        crossfadeJob = ownScope.launch { [weak self] in
            guard let self else { return }
            try await self.time.sleep(ms: delay)
            self.applyVolume()
        }
    }

    private static let crossfadeTickMs: Int64 = 33
    private static let keyCrossfade = "crossfade_seconds"
    private static let keyEqPreset = "eq_preset"
    private static let keyEqGains = "eq_gains"

    /// The player's volume is the song's own factor (from its loudness) times the fade of the sleep timer times the soft
    /// change between songs.
    private func applyVolume() {
        let id = engine.loadedItem?.videoId
        var gain: Float = 1
        if normalizeVolumeOn, let id {
            if let db = loudness[id] {
                gain = Loudness.gain(db)
            } else if let lookup = loudnessLookup, !looked.contains(id) {
                // Heard before, perhaps without a network now: the library has it
                looked.insert(id)
                Task { [weak self] in
                    guard let db = await lookup(id) else { return }
                    self?.loudnessLearned(id, db)
                }
            }
        }
        let volume = fade * gain * crossfadeRamp()
        scheduleCrossfadeTick()
        if volume == appliedVolume { return }
        appliedVolume = volume
        engine.setVolume(volume)
    }

    private var fade: Float = 1
    private var appliedVolume: Float = 1
    private var loudness: [String: Double] = [:]
    private var looked: Set<String> = []

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
    /// How long a request for tickets waits for the room, in milliseconds.
    private static let ticketWaitMs: UInt64 = 15_000
    private static let keyRoomSolo = "room_solo"
    private static let keyRoomSoloItem = "room_solo_item"
    private static let keyLastActive = "room_last_active"
    private static let keyAutoplay = "autoplay"
    private static let keyNormalizeVolume = "normalize_volume"
    private static let keyShareTaste = "share_taste"
    private static let tasteProtocol = 19
    private static let tasteText = 200
    private static let tasteDelayMs: Int64 = 3_000
    private static let keyVideo = "video_mode"

    /// Songs added each time the queue runs out and the music carries on by itself.
    private static let autoplayCount = 5

    /// The longest the app is held awake in the background for a room that ran out of songs.
    private static let idleHoldMs: Int64 = 25_000

    /// How long after the last try of autoplay in vain a network coming back earns it one more round.
    private static let autoplayOwedMs: Int64 = 5 * 60_000

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
    private let record: (TrackRef, String) -> Void
    private let recordSkip: (TrackRef, String) -> Void
    private let sourceOf: (QueueItem) -> String
    private let leftByOther: () -> Bool
    private let scrobblers: [Scrobbler]
    private var tracker: ListenTracker!

    /// The song being followed; kept whole so its details are not read from a player that has moved on.
    private var item: QueueItem?

    /// Where `item` came from, worked out when it started, because by the time it is left the queue has moved on.
    private var source = ListenSource.chosen
    private var due: Job?

    /// [sourceOf] says where a song came from when it starts; [leftByOther] whether the song just left was skipped by
    /// another member of the room, which is not a skip of this person's.
    init(engine: PlayerEngine, time: TimeSource, scope: Scope, record: @escaping (TrackRef, String) -> Void,
         recordSkip: @escaping (TrackRef, String) -> Void = { _, _ in },
         sourceOf: @escaping (QueueItem) -> String = { _ in ListenSource.chosen }, leftByOther: @escaping () -> Bool = { false },
         scrobblers: [Scrobbler] = []) {
        self.engine = engine
        self.time = time
        self.scope = scope
        self.record = record
        self.recordSkip = recordSkip
        self.sourceOf = sourceOf
        self.leftByOther = leftByOther
        self.scrobblers = scrobblers
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
            source = next.map(sourceOf) ?? ListenSource.chosen
        }
        if item != nil {
            tracker.setDuration(info.durationMs)
            tracker.setPlaying(info.playing, now: time.nowMs())
        }
        schedule()
        if !scrobblers.isEmpty {
            let track = item.map { TrackRef(videoId: $0.videoId, title: $0.title, artist: $0.artist, thumb: $0.thumb, durMs: info.durationMs,
                                            explicit: $0.explicit, year: $0.year) }
            for scrobbler in scrobblers { scrobbler.watch(track, playing: info.playing, durationMs: info.durationMs) }
        }
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
        if leftByOther() {
            EventLog.d("library", "'\(item.title)' was skipped by another member: not counted")
            return
        }
        EventLog.d("library", "skipped '\(item.title)' (\(source))")
        recordSkip(TrackRef(videoId: id, title: item.title, artist: item.artist, thumb: item.thumb, durMs: durationMs,
                            explicit: item.explicit, year: item.year), source)
    }

    private func heard(_ id: String, _ durationMs: Int64) {
        guard let item, item.videoId == id else { return }
        EventLog.d("library", "heard '\(item.title)' (\(source))")
        record(TrackRef(videoId: id, title: item.title, artist: item.artist, thumb: item.thumb, durMs: durationMs,
                        explicit: item.explicit, year: item.year), source)
    }
}
