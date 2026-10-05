import Foundation

/// What the session needs from a local audio player. Everything is called on the main thread.
@MainActor
protocol PlayerPort: AnyObject {
    /// Load [item] paused at [seekToMs]. Returns once playback can start instantly, and throws if the item cannot be
    /// loaded: a [LoadFailure] when the player knows why.
    func prepare(_ item: QueueItem, seekToMs: Int64) async throws

    /// Forget where [videoId] streams from, so that the next [prepare] of it asks for a new address. Someone trying
    /// again a song that stalled or failed wants that: the old address may be what is wrong, and it is kept for hours.
    func refresh(_ videoId: String) async

    /// Seek and return once the player is ready at the new position. Throws only when cancelled.
    func seekTo(_ positionMs: Int64) async throws

    func play()
    func pause()
    func stop()
    func setSpeed(_ speed: Float)

    /// Queue [item] to play right after the current one with no gap, replacing any earlier choice, or drop the queued
    /// item when nil. A no-op while nothing is loaded.
    func setNext(_ item: QueueItem?)

    func positionMs() -> Int64
    func isPlaying() -> Bool

    /// Called when the loaded item played to its end and nothing was queued after it.
    var onEnded: (() -> Void)? { get set }

    /// Called when the player moved on to the item given to [setNext] by itself.
    var onAdvanced: (() -> Void)? { get set }

    /// Called when playback fails after it started, e.g. the stream URL stopped working mid-track.
    var onError: ((Error) -> Void)? { get set }
}

/// Why [PlayerPort.prepare] could not load an item. Trying again at once does not help with either.
struct LoadFailure: Error, LocalizedError, Equatable {
    enum Reason: Equatable {
        /// The device has no network, and the song is not on it.
        case offline
        /// YouTube will not play this video: removed, private, blocked here, age restricted, live.
        case unplayable
    }

    let reason: Reason
    let message: String

    var errorDescription: String? { message }
}

/// Follows the room: turns server messages into player actions so that every device plays the same position at the
/// same moment. Everything runs on the main thread; message handlers only mutate state and launch jobs, and the jobs
/// interleave with handlers only at suspension points.
@MainActor
final class GroupSession {
    struct Snapshot: Equatable {
        var state: RoomState?
        var members: [Member] = []
        var you: String?
        /// Player position minus expected position, in ms; nil when not playing in sync.
        var driftMs: Int64?
        var speed: Float = 1
        /// Listening on this device alone: the room's transport no longer moves it.
        var solo = false
        /// Queue item this device is on while [solo]; the room's own current item is in [state].
        var soloItemId: String?
        /// While [solo], a song is on its way to play on this device.
        var loading = false
    }

    /// Something that happened to this device, worth telling the person about: mostly what another member did.
    enum RoomEvent: Equatable {
        case paused(byId: String)
        case skipped(byId: String, title: String)
        /// This device could not load [title], while the room may well be playing it; [reason] when it is known.
        case loadFailed(title: String, reason: LoadFailure.Reason?)
    }

    let events = SharedFlow<RoomEvent>()
    let snapshot = StateFlow<Snapshot>(Snapshot())

    private let scope: Scope
    private let player: PlayerPort
    private let clock: ClockSync
    private let time: TimeSource
    private let send: (String) -> Void
    private let log: (String) -> Void
    private let drift: DriftController

    private var state: RoomState?
    private var handledEpoch: Int64 = -1

    /// Server time of position 0 of the current item while playing in sync, else nil.
    private var startedAtServer: Int64?

    /// Queue item id currently loaded in the player, if any.
    private var loadedItemId: String?

    /// Listening alone: the player keeps to this device's own choices while the room's messages only update the view.
    private var solo = false
    private var soloJob: Job?

    /// Whether the song loading while alone plays once it is there; play and pause during the load only flip this.
    private var soloPlayOnLoad = false

    private var prepareJob: Job?
    private var startJob: Job?
    private var driftJob: Job?
    private let filter = DriftFilter()

    /// Diagnostics: when false, drift is measured and logged but never corrected.
    var correctionEnabled = true

    /// How long the last seek took; used to aim a little ahead when correcting drift by seeking.
    private var seekCostMs: Int64 = 150

    /// Item currently handed to the player as the gapless successor of the loaded one.
    private var preloaded: QueueItem?

    /// The room advanced before this device did; adopt its start time once the local player follows.
    private struct PendingAdopt {
        let itemId: String
        let startedAt: Int64
    }

    private var pendingAdopt: PendingAdopt?
    private var advanceJob: Job?

    /// Per-device correction in ms for output latency the player does not know about, e.g. a Bluetooth speaker.
    /// Positive means this device is heard late, so it plays that much ahead.
    var trimMs: Int64 = 0

    /// How much later than asked this device starts to be heard after play() or a seek, learned from earlier starts.
    /// Playback is aimed that far ahead so it lands on time. Seeded from storage.
    var startBiasMs: Int64 = 0
    var onStartBiasLearned: ((Int64) -> Void)?
    private var learnBias = false

    /// Recoveries used since the last epoch change; stops endless retry loops on a broken stream.
    private var recoveries = 0

    /// The item whose failed load the person was told about, so that retrying it does not tell them again and again.
    private var reportedFailure: String?

    init(scope: Scope, player: PlayerPort, clock: ClockSync, time: TimeSource? = nil,
         send: @escaping (String) -> Void, log: @escaping (String) -> Void = { _ in }, drift: DriftController = DriftController()) {
        self.scope = scope
        self.player = player
        self.clock = clock
        self.time = time ?? SystemTime.shared
        self.send = send
        self.log = log
        self.drift = drift

        player.onEnded = { [weak self] in
            guard let self else { return }
            self.scope.launch { [weak self] in
                guard let self else { return }
                if self.solo {
                    self.soloStep(+1, auto: true)
                } else if self.startedAtServer != nil {
                    self.log("item ended, reporting to room (epoch \(self.handledEpoch))")
                    self.send(Wire.ended(self.handledEpoch))
                }
            }
        }
        player.onError = { [weak self] error in
            guard let self else { return }
            self.scope.launch { [weak self] in self?.onPlayerError(error) }
        }
        player.onAdvanced = { [weak self] in
            guard let self else { return }
            self.scope.launch { [weak self] in self?.onLocalAdvance() }
        }
    }

    func onMessage(_ message: ServerMessage) {
        scope.launch { [weak self] in
            guard let self else { return }
            switch message {
            case let .state(_, you, state, members, _): self.onState(state: state, members: members, you: you)
            case let .members(members): self.snapshot.update { $0.members = members }
            case let .prepare(epoch, index, item, seekToMs, by): self.onPrepare(epoch: epoch, index: index, item: item, seekToMs: seekToMs, by: by)
            case let .start(epoch, startAt, positionMs, _): self.onStart(epoch: epoch, startAt: startAt, positionMs: positionMs)
            case let .pause(epoch, positionMs, by): self.onPause(epoch: epoch, positionMs: positionMs, by: by)
            case let .advance(epoch, index, startedAt): self.onAdvance(epoch: epoch, index: index, startedAt: startedAt)
            case .pong: break // consumed by the connection layer
            case .avatar: break // consumed by the connection layer too
            case .autoplayFill: break // answered by the controller, which can look for songs
            case let .error(code, message): self.log("server error \(code): \(message)")
            }
        }
    }

    /// Stop everything and silence the player. Done at once, not through [scope]: the caller cancels the scope right
    /// after, and work still waiting in it would never run and leave the room's song playing.
    func close() {
        held = false
        cancelPlayback()
        player.stop()
        loadedItemId = nil
        preloaded = nil
    }

    // ------------------------------------------------------------------ listening alone

    var isSolo: Bool { solo }

    /// Something outside the room stopped this device: another app took the sound, a headset or AirPods asked to pause.
    /// While held, what the room does (the next song, a start) loads here but does not play, so that this device does not
    /// take the sound back by itself; its person presses play, see `resumeHere`.
    private var held = false
    var isHeld: Bool { held }

    func hold() { held = true }

    func unhold() { held = false }

    /// The person pressed play on a held device while the room plays on: go to where the room is now and play from there,
    /// rather than play on from where the sound was lost and be corrected a moment later.
    func resumeHere() {
        scope.launch { [weak self] in
            guard let self else { return }
            self.held = false
            guard !self.solo, let s = self.state, let item = s.current, s.phase == "playing" else { return }
            guard let started = self.startedAtServer, self.loadedItemId == item.id else {
                // Not in step yet (the song came while held): load it and start where the room is
                self.cancelPlayback()
                self.startJob = self.scope.launch { [weak self] in try await self?.catchUpPlaying(item, s.startedAt) }
                return
            }
            let target = self.clock.toServer(self.time.nowMs()) - started + self.trimMs + self.seekCostMs + self.startBiasMs
            try await self.player.seekTo(max(target, 0))
            self.player.play()
            self.drift.reset()
            self.player.setSpeed(1)
            self.filter.reset(self.time.nowMs())
            self.learnBias = false // a start after being held says nothing about this device's output delay
            self.log("resumed here at \(target)ms after being held")
        }
    }

    /// The device plays in step with the room: the song is loaded, started, and the drift is being watched.
    var isInSync: Bool { startedAtServer != nil }

    /// Stop following the room and keep playing on this device alone. Whatever is playing goes on exactly as it is;
    /// from now on the room's play, pause and skip only update what is shown, and this device's own buttons act on
    /// this device only.
    func goSolo() {
        scope.launch { [weak self] in
            guard let self, !self.solo else { return }
            self.solo = true
            self.held = false
            self.prepareJob?.cancel()
            self.startJob?.cancel()
            self.driftJob?.cancel()
            self.clearPendingAdopt()
            self.startedAtServer = nil
            self.player.setSpeed(1)
            self.drift.reset()
            let item = self.loadedItemId
            self.snapshot.update { $0.solo = true; $0.soloItemId = item; $0.driftMs = nil; $0.speed = 1 }
            self.send(Wire.solo(true))
            self.log("listening on my own from '\(item ?? "nothing")'")
            self.soloPreload()
        }
    }

    /// Listening on one's own again after the app was killed: as [goSolo], but nothing is playing, so nothing starts
    /// until the person presses play, and then it is the song they were on. The room is told once the connection is
    /// up, see [onReconnected].
    func restoreSolo(itemId: String?) {
        scope.launch { [weak self] in
            guard let self, !self.solo else { return }
            self.solo = true
            self.snapshot.update { $0.solo = true; $0.soloItemId = itemId }
            self.log("back to listening on my own, on '\(itemId ?? "nothing")'")
        }
    }

    /// Follow the room again: ask it where it is and join in there.
    func rejoin() {
        scope.launch { [weak self] in
            guard let self, self.solo else { return }
            self.solo = false
            self.held = false
            self.soloJob?.cancel()
            self.handledEpoch = -1 // whatever the room says next counts, even if its epoch looks familiar
            self.preloaded = nil
            self.snapshot.update { $0.solo = false; $0.soloItemId = nil; $0.loading = false }
            self.send(Wire.solo(false))
            self.send(Wire.resync())
            self.log("following the room again")
        }
    }

    /// The connection came back: the server forgot that this device listens alone.
    func onReconnected() {
        scope.launch { [weak self] in
            guard let self, self.solo else { return }
            self.send(Wire.solo(true))
        }
    }

    func soloPlay() {
        scope.launch { [weak self] in
            guard let self else { return }
            if self.soloJob?.isActive == true {
                // The song is on its way: it plays once it is there
                self.soloPlayOnLoad = true
                self.snapshot.update { $0.loading = true }
            } else if self.loadedItemId != nil {
                self.player.play()
            } else {
                // After a restart the song this device was on, else wherever the room is
                let mine = self.state?.queue.first { $0.id == self.snapshot.value.soloItemId }
                if let item = mine ?? self.state?.current { self.soloLoad(item, 0, play: true) }
            }
        }
    }

    func soloPause() {
        scope.launch { [weak self] in
            guard let self else { return }
            // A song still on its way stays paused when it gets there
            self.soloPlayOnLoad = false
            self.snapshot.update { $0.loading = false }
            self.player.pause()
        }
    }

    func soloSeek(_ positionMs: Int64) {
        scope.launch { [weak self] in
            guard let self, self.loadedItemId != nil else { return }
            try await self.player.seekTo(max(positionMs, 0))
        }
    }

    /// Next in the queue after the one this device is on.
    func soloNext() {
        scope.launch { [weak self] in self?.soloStep(+1, auto: false) }
    }

    /// Restart this song, or go to the one before it when it has only just begun.
    func soloPrev() {
        scope.launch { [weak self] in
            guard let self else { return }
            if self.player.positionMs() > Self.prevRestartsAfterMs {
                try await self.player.seekTo(0)
            } else {
                self.soloStep(-1, auto: false)
            }
        }
    }

    func soloJump(_ itemId: String) {
        scope.launch { [weak self] in
            guard let self, let item = self.state?.queue.first(where: { $0.id == itemId }) else { return }
            self.soloLoad(item, 0, play: true)
        }
    }

    /// Moves [delta] items along the room's queue from where this device is.
    private func soloStep(_ delta: Int, auto: Bool) {
        guard let s = state else { return }
        let at = s.queue.firstIndex { $0.id == snapshot.value.soloItemId } ?? -1
        var target = at < 0 ? s.index : at + delta
        if auto && s.repeatMode == "one" && at >= 0 { target = at }
        if target >= s.queue.count { target = s.repeatMode == "all" ? 0 : -1 }
        if target < 0 {
            if delta < 0 && !s.queue.isEmpty {
                target = 0
            } else {
                // Ran out of songs: stop where we are
                player.pause()
                return
            }
        }
        soloLoad(s.queue[target], 0, play: true)
    }

    private func soloLoad(_ item: QueueItem, _ positionMs: Int64, play: Bool) {
        soloJob?.cancel()
        preloaded = nil
        soloPlayOnLoad = play
        snapshot.update { $0.loading = play }
        soloJob = scope.launch { [weak self] in
            guard let self else { return }
            do {
                try await self.player.prepare(item, seekToMs: positionMs)
                self.loaded(item)
                self.snapshot.update { $0.soloItemId = item.id; $0.loading = false }
                if self.soloPlayOnLoad { self.player.play() }
                self.soloPreload()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.log("could not load '\(item.title)' while alone: \(error.localizedDescription)")
                self.loadedItemId = nil
                self.snapshot.update { $0.loading = false }
                self.loadFailed(item, error)
            }
        }
    }

    /// While alone, keep the gapless successor equal to the song after the one this device is on.
    private func soloPreload() {
        let mine = snapshot.value.soloItemId
        var wanted: QueueItem?
        if solo, let s = state, let mine, mine == loadedItemId, s.repeatMode != "one" {
            if let at = s.queue.firstIndex(where: { $0.id == mine }), s.queue.indices.contains(at + 1) {
                wanted = s.queue[at + 1]
            }
        }
        if wanted == preloaded { return }
        preloaded = wanted
        player.setNext(wanted)
    }

    // ------------------------------------------------------------------ handlers

    private func onState(state newState: RoomState, members: [Member], you: String) {
        state = newState
        snapshot.update { $0.state = newState; $0.members = members; $0.you = you }
        if solo {
            soloPreload() // the queue may have changed under us
            return
        }

        // Same or older epoch: we already follow this room (e.g. the queue changed). Nothing to do.
        if newState.epoch <= handledEpoch {
            if startedAtServer != nil { syncPreload() } // e.g. a track was added after the current one
            return
        }

        switch newState.phase {
        case "preparing":
            break // a prepare message follows; it starts the barrier
        case "idle":
            handledEpoch = newState.epoch
            cancelPlayback()
            player.stop()
            loadedItemId = nil
            preloaded = nil
        case "paused":
            handledEpoch = newState.epoch
            cancelPlayback()
            guard let item = newState.current else { return }
            log("catching up: paused at \(newState.positionMs)ms")
            startJob = scope.launch { [weak self] in await self?.loadPaused(item, newState.positionMs) }
        case "playing":
            handledEpoch = newState.epoch
            cancelPlayback()
            guard let item = newState.current else { return }
            if loadedItemId == item.id {
                // Reconnected while already on this item: keep playing, only realign
                log("resyncing without reloading")
                startJob = scope.launch { [weak self] in try await self?.resumeLoaded(item, newState.startedAt) }
            } else {
                log("catching up: room is playing")
                startJob = scope.launch { [weak self] in try await self?.catchUpPlaying(item, newState.startedAt) }
            }
        default:
            break
        }
        if startedAtServer != nil { syncPreload() } // the queue may have changed
    }

    /// Applies a change the server announced without sending the whole state again.
    private func updateRoom(_ change: (inout RoomState) -> Void) {
        guard var current = state else { return }
        change(&current)
        state = current
        snapshot.update { $0.state = current }
    }

    private func onPrepare(epoch: Int64, index: Int, item: QueueItem, seekToMs: Int64, by: String?) {
        if solo {
            updateRoom { $0.phase = "preparing"; $0.index = index; $0.epoch = epoch; $0.positionMs = seekToMs }
            return
        }
        if epoch < handledEpoch { return }
        if let by, by != snapshot.value.you, epoch != handledEpoch {
            events.emit(.skipped(byId: by, title: item.title))
        }
        if epoch == handledEpoch {
            // The server repeats the prepare to a device that reconnected mid-barrier
            if prepareJob?.isActive == true { return }
            if loadedItemId == item.id {
                send(Wire.ready(epoch))
                return
            }
        }
        if epoch != handledEpoch { recoveries = 0 }
        handledEpoch = epoch
        cancelPlayback()
        loadedItemId = nil
        preloaded = nil
        prepareJob = scope.launch { [weak self] in
            guard let self else { return }
            do {
                let t0 = self.time.nowMs()
                try await self.player.prepare(item, seekToMs: seekToMs)
                self.loaded(item)
                self.log("prepared '\(item.title)' in \(self.time.nowMs() - t0)ms, reporting ready (epoch \(epoch))")
                self.send(Wire.ready(epoch))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.log("prepare failed: \(error.localizedDescription)")
                self.send(Wire.resolveFailed(epoch, reason: error.localizedDescription))
                self.loadFailed(item, error)
            }
        }
    }

    private func onStart(epoch: Int64, startAt: Int64, positionMs: Int64) {
        if solo {
            updateRoom { $0.phase = "playing"; $0.epoch = epoch; $0.positionMs = positionMs; $0.startedAt = startAt - positionMs }
            return
        }
        if epoch < handledEpoch { return }
        let waitForOwnPrepare = epoch == handledEpoch && prepareJob?.isActive == true
        handledEpoch = epoch
        // The server announces the start with this message only, so the UI's copy of the phase moves here
        updateRoom { $0.phase = "playing"; $0.epoch = epoch; $0.positionMs = positionMs; $0.startedAt = startAt - positionMs }
        // Keep our own prepare running: a slow device still needs to finish loading
        startJob?.cancel()
        driftJob?.cancel()
        clearPendingAdopt()
        startedAtServer = nil
        player.pause()

        let item = state?.current
        startJob = scope.launch { [weak self] in
            guard let self else { return }
            if waitForOwnPrepare { await self.prepareJob?.join() }
            if self.loadedItemId == nil || (item != nil && self.loadedItemId != item!.id) {
                // Missed the prepare (e.g. reconnected): load whatever the room is on now
                guard let item else { return }
                await self.loadPaused(item, positionMs)
            }
            if self.loadedItemId == nil { return } // could not load; sit this one out
            try await self.runStart(startAt, positionMs)
        }
    }

    private func onPause(epoch: Int64, positionMs: Int64, by: String?) {
        if solo {
            updateRoom { $0.phase = "paused"; $0.epoch = epoch; $0.positionMs = positionMs }
            return
        }
        if epoch < handledEpoch { return }
        handledEpoch = epoch
        if let by, by != snapshot.value.you { events.emit(.paused(byId: by)) }
        updateRoom { $0.phase = "paused"; $0.epoch = epoch; $0.positionMs = positionMs }
        cancelPlayback()
        let item = state?.current
        startJob = scope.launch { [weak self] in
            guard let self else { return }
            if self.loadedItemId != nil {
                try await self.player.seekTo(positionMs)
            } else if let item {
                await self.loadPaused(item, positionMs)
            }
        }
    }

    /// The room moved on to the next item. A device that already did so keeps playing, one that is about to do so
    /// waits for its player, and anything else loads the item like a late joiner.
    private func onAdvance(epoch: Int64, index: Int, startedAt: Int64) {
        if solo {
            updateRoom { $0.index = index; $0.epoch = epoch; $0.startedAt = startedAt; $0.positionMs = 0; $0.phase = "playing" }
            return
        }
        if epoch <= handledEpoch { return }
        guard let current = state, current.queue.indices.contains(index) else { return }
        let item = current.queue[index]
        handledEpoch = epoch
        recoveries = 0
        var advanced = current
        advanced.index = index
        advanced.epoch = epoch
        advanced.startedAt = startedAt
        advanced.positionMs = 0
        advanced.phase = "playing"
        state = advanced
        snapshot.update { $0.state = advanced }

        if loadedItemId == item.id {
            adopt(startedAt)
        } else if preloaded?.id == item.id {
            // Our player is still finishing the previous item and will move on within moments
            driftJob?.cancel()
            startedAtServer = nil
            pendingAdopt = PendingAdopt(itemId: item.id, startedAt: startedAt)
            advanceJob?.cancel()
            advanceJob = scope.launch { [weak self] in
                guard let self else { return }
                guard await self.time.wait(ms: Self.advanceWaitMs) else { return }
                guard let stuck = self.pendingAdopt else { return }
                self.log("player did not advance in time, loading the item")
                self.pendingAdopt = nil
                self.cancelPlayback()
                self.startJob = self.scope.launch { [weak self] in try await self?.catchUpPlaying(item, stuck.startedAt) }
            }
        } else {
            cancelPlayback()
            startJob = scope.launch { [weak self] in try await self?.catchUpPlaying(item, startedAt) }
        }
    }

    /// The player switched to the preloaded item by itself.
    private func onLocalAdvance() {
        guard let item = preloaded else { return }
        preloaded = nil
        loadedItemId = item.id
        if solo {
            snapshot.update { $0.soloItemId = item.id }
            soloPreload()
            return
        }
        if let pending = pendingAdopt, pending.itemId == item.id {
            adopt(pending.startedAt)
            return
        }
        if startedAtServer == nil { return } // not following the room in sync, nothing to report

        let epoch = handledEpoch
        driftJob?.cancel()
        startedAtServer = nil // the position restarted at zero: the old start time no longer applies
        log("advanced locally to '\(item.title)'")

        advanceJob?.cancel()
        advanceJob = scope.launch { [weak self] in
            guard let self else { return }
            guard await self.time.wait(ms: Self.advanceReportDelayMs) else { return } // let the position settle so the reported start is accurate
            if self.handledEpoch != epoch || self.loadedItemId != item.id { return } // the server answered or moved on
            let startedAt = self.clock.toServer(self.time.nowMs()) - self.player.positionMs()
            if self.player.isPlaying() { self.send(Wire.advanced(epoch, itemId: item.id, startedAt: startedAt)) }
            // The server normally answers with an advance message; if it does not (offline), follow our own clock
            guard await self.time.wait(ms: Self.advanceWaitMs) else { return }
            if self.handledEpoch == epoch && self.startedAtServer == nil && self.loadedItemId == item.id {
                self.log("no answer from the room, following the local start")
                self.adopt(self.clock.toServer(self.time.nowMs()) - self.player.positionMs())
            }
        }
    }

    /// Follow the room's clock for the item the player is on right now.
    private func adopt(_ startedAt: Int64) {
        clearPendingAdopt()
        advanceJob?.cancel()
        startedAtServer = startedAt
        startDriftLoop()
        syncPreload()
        log("following '\(state?.current?.title ?? "")' from server time \(startedAt)")
    }

    private func clearPendingAdopt() {
        pendingAdopt = nil
        advanceJob?.cancel()
    }

    /// Keep the player's gapless successor equal to the item after the current one, while following the room.
    private func syncPreload() {
        let s = state
        // Repeating one item is not gapless: it ends and the server starts it over through a barrier
        let following = startedAtServer != nil && s != nil && s!.current?.id == loadedItemId && s!.repeatMode != "one"
        var wanted: QueueItem?
        if following, let s, s.queue.indices.contains(s.index + 1) { wanted = s.queue[s.index + 1] }
        if wanted == preloaded { return }
        preloaded = wanted
        player.setNext(wanted)
    }

    /// The stream broke while we were playing in sync. Reload it and rejoin at the position the room has reached,
    /// exactly like a late joiner. Gives up after a few attempts per epoch.
    private func onPlayerError(_ error: Error) {
        guard let startedAt = startedAtServer else { return } // not playing in sync: prepare deals with its own errors
        guard let item = state?.current else { return }
        recoveries += 1
        if recoveries > Self.maxRecoveriesPerEpoch {
            log("player error, giving up after \(Self.maxRecoveriesPerEpoch) recoveries: \(error.localizedDescription)")
            // Silent while the room plays on: play tries again (see catchUp)
            startedAtServer = nil
            loadedItemId = nil
            loadFailed(item, error)
            return
        }
        log("player error, recovering (#\(recoveries)): \(error.localizedDescription)")
        cancelPlayback()
        startJob = scope.launch { [weak self] in try await self?.catchUpPlaying(item, startedAt) }
    }

    // ------------------------------------------------------------------ playback

    private func loadPaused(_ item: QueueItem, _ positionMs: Int64) async {
        do {
            preloaded = nil // preparing replaces the whole playlist
            try await player.prepare(item, seekToMs: positionMs)
            loaded(item)
        } catch is CancellationError {
            // Replaced by something newer
        } catch {
            log("load failed: \(error.localizedDescription)")
            loadedItemId = nil
            loadFailed(item, error)
        }
    }

    private func loaded(_ item: QueueItem) {
        loadedItemId = item.id
        reportedFailure = nil
    }

    /// Tells the person, once for each item, that this device could not load it: the room may play on without it.
    private func loadFailed(_ item: QueueItem, _ error: Error) {
        if reportedFailure == item.id { return }
        reportedFailure = item.id
        events.emit(.loadFailed(title: item.title, reason: (error as? LoadFailure)?.reason))
    }

    /// Play was pressed while the room plays a song this device does not have (it could not load it, or gave up on a
    /// broken stream): load it again and join in where the room is, instead of pressing play on an empty player.
    /// Returns false when this device has the song, so that play just resumes it.
    func catchUp() -> Bool {
        guard !solo, loadedItemId == nil, let s = state, let item = s.current, s.phase == "playing" else { return false }
        scope.launch { [weak self] in
            guard let self, !self.solo, self.loadedItemId == nil, self.startJob?.isActive != true,
                  self.prepareJob?.isActive != true else { return }
            self.reportedFailure = nil // a new try by hand is told about again if it fails
            self.log("play pressed with nothing loaded, catching up with the room")
            self.startJob = self.scope.launch { [weak self] in try await self?.catchUpPlaying(item, s.startedAt) }
        }
        return true
    }

    /// The item is already loaded (e.g. after a reconnect): realign to the room's clock and make sure it plays.
    private func resumeLoaded(_ item: QueueItem, _ startedAt: Int64) async throws {
        if !player.isPlaying() && !held {
            let target = clock.toServer(time.nowMs()) - startedAt + seekCostMs
            try await player.seekTo(max(target, 0))
            player.play()
        }
        loadedItemId = item.id
        adopt(startedAt)
    }

    /// Join a room that is already playing: load, then start at whatever position it has reached. If loading fails
    /// (typically no network yet) it tries again every few seconds until a newer message cancels this job.
    private func catchUpPlaying(_ item: QueueItem, _ startedAt: Int64) async throws {
        var attempt = 0
        while true {
            let guessed = clock.toServer(time.nowMs()) - startedAt + Self.catchUpLoadGuessMs
            await loadPaused(item, max(guessed, 0))
            try Task.checkCancellation()
            if loadedItemId != nil { break }
            attempt += 1
            if attempt >= Self.catchUpMaxAttempts {
                log("giving up loading '\(item.title)' after \(attempt) attempts")
                return
            }
            try await time.sleep(ms: Self.catchUpRetryMs)
        }
        let targetServer = clock.toServer(time.nowMs()) + Self.catchUpLeadMs
        try await runStart(targetServer, max(targetServer - startedAt, 0))
    }

    /// Play position [positionMs] at server time [startAtServer]; if that moment has passed, skip ahead.
    private func runStart(_ startAtServer: Int64, _ positionMs: Int64) async throws {
        let startLocal = clock.toLocal(startAtServer)
        if startLocal - time.nowMs() > Self.minTimeToAlignMs {
            try await player.seekTo(positionMs + startBiasMs)
            let wait = startLocal - time.nowMs()
            if wait > 0 { try await time.sleep(ms: wait) }
            if !held { player.play() }
            log("\(held ? "held, not playing" : "play()") at scheduled time, position \(positionMs)")
        } else {
            let late = time.nowMs() - startLocal
            let target = positionMs + max(late, 0) + seekCostMs + startBiasMs
            try await player.seekTo(target)
            if !held { player.play() }
            log("\(held ? "held, not playing" : "play()") late by \(late)ms, skipped to \(target)")
        }
        drift.reset()
        player.setSpeed(1)
        startedAtServer = startAtServer - positionMs
        learnBias = !held
        startDriftLoop()
        syncPreload()
    }

    private func startDriftLoop() {
        driftJob?.cancel()
        driftJob = scope.launch { [weak self] in
            guard let self else { return }
            var settleUntil: Int64 = 0
            var tick = 0
            var playingTicks = 0
            self.filter.reset(self.time.nowMs())
            while true {
                guard await self.time.wait(ms: Self.driftTickMs) else { return }
                guard let started = self.startedAtServer else { return }
                if !self.player.isPlaying() {
                    playingTicks = 0
                    self.snapshot.update { $0.driftMs = nil }
                    // Readings from before a stall say nothing about the position after it
                    self.filter.reset(self.time.nowMs(), speed: self.snapshot.value.speed)
                    continue // buffering or paused: nothing meaningful to measure
                }
                playingTicks += 1
                if playingTicks >= Self.healthyTicks { self.recoveries = 0 }
                let now = self.time.nowMs()
                let expected = self.clock.toServer(now) - started + self.trimMs
                let driftMs = self.player.positionMs() - expected
                self.snapshot.update { $0.driftMs = driftMs }
                if now < settleUntil { continue } // let a recent seek settle before measuring again
                self.filter.add(now, driftMs)
                guard let smoothed = self.filter.estimate(now) else { continue }
                tick += 1
                if tick % Self.logEveryTicks == 0 {
                    self.log("drift=\(driftMs)ms smoothed=\(smoothed)ms offset=\(Int64(self.clock.offsetMs()))ms rtt=\(self.clock.bestRttMs().map { String(Int64($0)) } ?? "-")ms")
                }
                if self.learnBias && self.filter.isFull { self.learnStartBias() }
                if !self.correctionEnabled { continue }
                let trusted = abs(smoothed) > self.drift.seekThresholdMs ? self.filter.hasLargeDriftEvidence : self.filter.isFull
                if !trusted { continue }

                switch self.drift.decide(smoothed) {
                case .none:
                    break
                case let .setSpeed(factor):
                    self.player.setSpeed(factor)
                    self.filter.setSpeed(now, factor)
                    self.snapshot.update { $0.speed = factor }
                    self.log("drift=\(smoothed)ms (smoothed) -> speed \(factor)")
                case .seek:
                    let before = self.time.nowMs()
                    // Aim a little ahead: the seek itself takes time
                    let target = self.clock.toServer(before) - started + self.seekCostMs + self.trimMs
                    self.learnBias = false // a corrective seek muddies what the plain start looked like
                    try await self.player.seekTo(target)
                    self.seekCostMs = min(max(self.time.nowMs() - before, 50), 1000)
                    self.player.setSpeed(1)
                    self.filter.reset(self.time.nowMs())
                    self.snapshot.update { $0.speed = 1 }
                    settleUntil = self.time.nowMs() + Self.settleAfterSeekMs
                    self.log("drift=\(smoothed)ms (smoothed) -> seek to \(target) (took \(self.seekCostMs)ms)")
                }
            }
        }
    }

    /// The first full window after a plain start shows how far off that start was; fold it into the bias.
    private func learnStartBias() {
        learnBias = false
        guard let residual = filter.uncorrectedMean() else { return }
        let updated = Int64((Double(startBiasMs) - residual * Self.biasLearningRate).rounded(.towardZero))
        let clamped = min(max(updated, -Self.maxBiasMs), Self.maxBiasMs)
        log("start was \(Int64(residual))ms off, start bias \(startBiasMs) -> \(clamped)ms")
        startBiasMs = clamped
        onStartBiasLearned?(clamped)
    }

    private func cancelPlayback() {
        learnBias = false
        prepareJob?.cancel()
        startJob?.cancel()
        driftJob?.cancel()
        clearPendingAdopt()
        startedAtServer = nil
        player.pause()
        player.setSpeed(1)
        drift.reset()
        snapshot.update { $0.driftMs = nil; $0.speed = 1 }
    }

    /// Below this much time to the scheduled start there is no point in seeking first.
    private static let minTimeToAlignMs: Int64 = 120
    private static let driftTickMs: Int64 = 500
    private static let logEveryTicks = 2 // every second
    private static let settleAfterSeekMs: Int64 = 1500
    private static let catchUpLoadGuessMs: Int64 = 2000
    private static let catchUpLeadMs: Int64 = 400
    private static let catchUpRetryMs: Int64 = 5000
    private static let catchUpMaxAttempts = 60 // about five minutes plus the time each attempt takes

    /// Continuous playing this long counts as healthy again: earlier recoveries are forgotten.
    private static let healthyTicks = 60
    private static let maxRecoveriesPerEpoch = 5
    private static let biasLearningRate = 0.8
    private static let maxBiasMs: Int64 = 800

    /// After moving to the next item by itself, wait this long before reporting when it started.
    private static let advanceReportDelayMs: Int64 = 1000

    /// How long to wait for the room's answer, or for our own player, around a gapless advance.
    private static let advanceWaitMs: Int64 = 4000

    /// Like most players: "previous" restarts the song unless it has only just begun.
    private static let prevRestartsAfterMs: Int64 = 3000
}
