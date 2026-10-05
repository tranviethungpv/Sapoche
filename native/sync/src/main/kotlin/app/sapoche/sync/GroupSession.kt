package app.sapoche.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.abs

/** What the session needs from a local audio player. Implementations must be safe to call from any thread. */
interface PlayerPort {
    /**
     * Load [item] paused at [seekToMs]. Returns once playback can start instantly, and throws if
     * the item cannot be loaded: a [LoadFailure] when the player knows why.
     */
    suspend fun prepare(item: QueueItem, seekToMs: Long)

    /**
     * Forget where [videoId] streams from, so that the next [prepare] of it asks for a new address. Someone trying
     * again a song that stalled or failed wants that: the old address may be what is wrong, and it is kept for hours.
     */
    fun refresh(videoId: String)

    /**
     * Seek and return once the player is ready at the new position, or once it gave up waiting. Never throws but to
     * be cancelled: a stream that breaks meanwhile goes to [onError].
     */
    suspend fun seekTo(positionMs: Long)

    fun play()
    fun pause()
    fun stop()
    fun setSpeed(speed: Float)

    /**
     * Queue [item] to play right after the current one with no gap, replacing any earlier choice, or
     * drop the queued item when null. A no-op while nothing is loaded.
     */
    fun setNext(item: QueueItem?)

    fun positionMs(): Long
    fun isPlaying(): Boolean

    /** Called when the loaded item played to its end and nothing was queued after it. */
    var onEnded: (() -> Unit)?

    /** Called when the player moved on to the item given to [setNext] by itself. */
    var onAdvanced: (() -> Unit)?

    /** Called when playback fails after it started, e.g. the stream URL stopped working mid-track. */
    var onError: ((Exception) -> Unit)?
}

/** Why [PlayerPort.prepare] could not load an item. Trying again at once does not help with either. */
class LoadFailure(val reason: Reason, message: String, cause: Throwable? = null) : java.io.IOException(message, cause) {
    enum class Reason {
        /** The device has no network, and the song is not on it. */
        OFFLINE,

        /** YouTube will not play this video: removed, private, blocked here, age restricted, live. */
        UNPLAYABLE,
    }

    companion object {
        /** The [LoadFailure] behind [error], however deep the player wrapped it. */
        fun of(error: Throwable?): LoadFailure? = generateSequence(error) { it.cause }.take(8).firstOrNull { it is LoadFailure } as LoadFailure?
    }
}

/**
 * Follows the room: turns server messages into player actions so that every device plays the same
 * position at the same moment.
 *
 * [scope] must run on a single thread. Message handlers only mutate state and launch jobs; the
 * jobs themselves interleave with handlers only at suspension points.
 */
class GroupSession(
    private val scope: CoroutineScope,
    private val player: PlayerPort,
    private val clock: ClockSync,
    /** Monotonic local clock in ms, the same one the clock sync samples come from. */
    private val nowMs: () -> Long,
    private val send: (String) -> Unit,
    private val log: (String) -> Unit = {},
    private val drift: DriftController = DriftController(),
) {
    data class Snapshot(
        val state: RoomState? = null,
        val members: List<Member> = emptyList(),
        val you: String? = null,
        /** Player position minus expected position, in ms; null when not playing in sync. */
        val driftMs: Long? = null,
        val speed: Float = 1f,
        /** Listening on this device alone: the room's transport no longer moves it. */
        val solo: Boolean = false,
        /** Queue item this device is on while [solo]; the room's own current item is in [state]. */
        val soloItemId: String? = null,
        /** While [solo], a song is on its way to play on this device. */
        val loading: Boolean = false,
    )

    /** Something that happened to this device, worth telling the person about: mostly what another member did. */
    sealed interface RoomEvent {
        data class Paused(val byId: String) : RoomEvent
        data class Skipped(val byId: String, val title: String) : RoomEvent

        /** This device could not load [title], while the room may well be playing it; [reason] when it is known. */
        data class LoadFailed(val title: String, val reason: LoadFailure.Reason?) : RoomEvent
    }

    private val _events = MutableSharedFlow<RoomEvent>(extraBufferCapacity = 8)
    val events: SharedFlow<RoomEvent> = _events.asSharedFlow()

    private val _snapshot = MutableStateFlow(Snapshot())
    val snapshot: StateFlow<Snapshot> = _snapshot.asStateFlow()

    private var state: RoomState? = null
    private var handledEpoch = -1L

    /** Server time of position 0 of the current item while playing in sync, else null. */
    private var startedAtServer: Long? = null

    /** Queue item id currently loaded in the player, if any. */
    private var loadedItemId: String? = null

    /** Listening alone: the player keeps to this device's own choices while the room's messages only update the view. */
    private var solo = false
    private var soloJob: Job? = null

    /** Whether the song loading while alone plays once it is there; play and pause during the load only flip this. */
    private var soloPlayOnLoad = false

    private var prepareJob: Job? = null
    private var startJob: Job? = null
    private var driftJob: Job? = null
    private val filter = DriftFilter()

    /** Diagnostics: when false, drift is measured and logged but never corrected. */
    @Volatile var correctionEnabled = true

    /** How long the last seek took; used to aim a little ahead when correcting drift by seeking. */
    private var seekCostMs = 150L

    /** Item currently handed to the player as the gapless successor of the loaded one. */
    private var preloaded: QueueItem? = null

    /** The room advanced before this device did; adopt its start time once the local player follows. */
    private class PendingAdopt(val itemId: String, val startedAt: Long)
    private var pendingAdopt: PendingAdopt? = null
    private var advanceJob: Job? = null

    /**
     * Per-device correction in ms for output latency the player does not know about, e.g. a
     * Bluetooth speaker. Positive means this device is heard late, so it plays that much ahead.
     */
    @Volatile var trimMs = 0L

    /**
     * How much later than asked this device starts to be heard after play() or a seek, learned from
     * earlier starts. Playback is aimed that far ahead so it lands on time. Seeded from storage.
     */
    @Volatile var startBiasMs = 0L
    var onStartBiasLearned: ((Long) -> Unit)? = null
    private var learnBias = false

    /** Recoveries used since the last epoch change; stops endless retry loops on a broken stream. */
    private var recoveries = 0

    /** The item whose failed load the person was told about, so that retrying it does not tell them again and again. */
    private var reportedFailure: String? = null

    init {
        player.onEnded = {
            scope.launch {
                if (solo) {
                    soloStep(+1, auto = true)
                } else if (startedAtServer != null) {
                    log("item ended, reporting to room (epoch $handledEpoch)")
                    send(Protocol.ended(handledEpoch))
                }
            }
        }
        player.onError = { error -> scope.launch { onPlayerError(error) } }
        player.onAdvanced = { scope.launch { onLocalAdvance() } }
    }

    fun onMessage(message: ServerMessage) {
        scope.launch {
            when (message) {
                is ServerMessage.State -> onState(message)
                is ServerMessage.Members -> _snapshot.update { it.copy(members = message.members) }
                is ServerMessage.Prepare -> onPrepare(message)
                is ServerMessage.Start -> onStart(message)
                is ServerMessage.Pause -> onPause(message)
                is ServerMessage.Advance -> onAdvance(message)
                is ServerMessage.Pong -> Unit // consumed by the connection layer
                is ServerMessage.Avatar -> Unit // consumed by the connection layer too
                is ServerMessage.AutoplayFill -> Unit // answered by the controller, which can look for songs
                is ServerMessage.Error -> log("server error ${message.code}: ${message.message}")
            }
        }
    }

    /**
     * Stop everything and silence the player. Done at once, not through [scope]: the caller cancels the scope
     * right after, and work still waiting in it would never run and leave the room's song playing.
     */
    fun close() {
        held = false
        cancelPlayback()
        player.stop()
        loadedItemId = null
        preloaded = null
    }

    // ------------------------------------------------------------------ listening alone

    val isSolo: Boolean get() = solo

    /**
     * Something outside the room stopped this device: another app took the sound, a headset or AirPods asked to pause.
     * While held, what the room does (the next song, a start) loads here but does not play, so that this device does
     * not take the sound back by itself; its person presses play, see [resumeHere].
     */
    private var held = false
    val isHeld: Boolean get() = held

    fun hold() {
        held = true
    }

    fun unhold() {
        held = false
    }

    /**
     * The person pressed play on a held device while the room plays on: go to where the room is now and play from there,
     * rather than play on from where the sound was lost and be corrected a moment later.
     */
    fun resumeHere() {
        scope.launch {
            held = false
            val started = startedAtServer
            val item = state?.current
            if (solo || item == null || state?.phase != "playing") return@launch
            if (started == null || loadedItemId != item.id) {
                // Not in step yet (the song came while held): load it and start where the room is
                cancelPlayback()
                startJob = scope.launch { catchUpPlaying(item, state?.startedAt ?: return@launch) }
                return@launch
            }
            val target = clock.toServer(nowMs()) - started + trimMs + seekCostMs + startBiasMs
            player.seekTo(target.coerceAtLeast(0))
            player.play()
            drift.reset()
            player.setSpeed(1f)
            filter.reset(nowMs())
            learnBias = false // a start after being held says nothing about this device's output delay
            log("resumed here at ${target}ms after being held")
        }
    }

    /** The device plays in step with the room: the song is loaded, started, and the drift is being watched. */
    val isInSync: Boolean get() = startedAtServer != null

    /**
     * Stop following the room and keep playing on this device alone. Whatever is playing goes on
     * exactly as it is; from now on the room's play, pause and skip only update what is shown, and
     * this device's own buttons act on this device only.
     */
    fun goSolo() {
        scope.launch {
            if (solo) return@launch
            solo = true
            held = false
            prepareJob?.cancel()
            startJob?.cancel()
            driftJob?.cancel()
            clearPendingAdopt()
            startedAtServer = null
            player.setSpeed(1f)
            drift.reset()
            _snapshot.update { it.copy(solo = true, soloItemId = loadedItemId, driftMs = null, speed = 1f) }
            send(Protocol.solo(true))
            log("listening on my own from '${loadedItemId}'")
            soloPreload()
        }
    }

    /**
     * Listening on one's own again after the app was killed: as [goSolo], but nothing is playing, so
     * nothing starts until the person presses play, and then it is the song they were on. The room is
     * told once the connection is up, see [onReconnected].
     */
    fun restoreSolo(itemId: String?) {
        scope.launch {
            if (solo) return@launch
            solo = true
            _snapshot.update { it.copy(solo = true, soloItemId = itemId) }
            log("back to listening on my own, on '$itemId'")
        }
    }

    /** Follow the room again: ask it where it is and join in there. */
    fun rejoin() {
        scope.launch {
            if (!solo) return@launch
            solo = false
            held = false
            soloJob?.cancel()
            handledEpoch = -1 // whatever the room says next counts, even if its epoch looks familiar
            preloaded = null
            _snapshot.update { it.copy(solo = false, soloItemId = null, loading = false) }
            send(Protocol.solo(false))
            send(Protocol.resync())
            log("following the room again")
        }
    }

    /** The connection came back: the server forgot that this device listens alone. */
    fun onReconnected() {
        scope.launch { if (solo) send(Protocol.solo(true)) }
    }

    fun soloPlay() {
        scope.launch {
            if (soloJob?.isActive == true) {
                // The song is on its way: it plays once it is there
                soloPlayOnLoad = true
                _snapshot.update { it.copy(loading = true) }
            } else if (loadedItemId != null) {
                player.play()
            } else {
                // After a restart the song this device was on, else wherever the room is
                val mine = state?.queue?.firstOrNull { it.id == _snapshot.value.soloItemId }
                (mine ?: state?.current)?.let { soloLoad(it, 0, play = true) }
            }
        }
    }

    fun soloPause() {
        scope.launch {
            // A song still on its way stays paused when it gets there
            soloPlayOnLoad = false
            _snapshot.update { it.copy(loading = false) }
            player.pause()
        }
    }

    fun soloSeek(positionMs: Long) {
        scope.launch { if (loadedItemId != null) player.seekTo(positionMs.coerceAtLeast(0)) }
    }

    /** Next in the queue after the one this device is on. */
    fun soloNext() {
        scope.launch { soloStep(+1, auto = false) }
    }

    /** Restart this song, or go to the one before it when it has only just begun. */
    fun soloPrev() {
        scope.launch {
            if (player.positionMs() > PREV_RESTARTS_AFTER_MS) soloSeek(0) else soloStep(-1, auto = false)
        }
    }

    fun soloJump(itemId: String) {
        scope.launch { state?.queue?.firstOrNull { it.id == itemId }?.let { soloLoad(it, 0, play = true) } }
    }

    /** Moves [delta] items along the room's queue from where this device is. */
    private fun soloStep(delta: Int, auto: Boolean) {
        val s = state ?: return
        val at = s.queue.indexOfFirst { it.id == _snapshot.value.soloItemId }
        var target = if (at < 0) s.index else at + delta
        if (auto && s.repeat == "one" && at >= 0) target = at
        if (target >= s.queue.size) target = if (s.repeat == "all") 0 else -1
        if (target < 0) {
            if (delta < 0 && s.queue.isNotEmpty()) target = 0 else {
                // Ran out of songs: stop where we are
                player.pause()
                return
            }
        }
        soloLoad(s.queue[target], 0, play = true)
    }

    private fun soloLoad(item: QueueItem, positionMs: Long, play: Boolean) {
        soloJob?.cancel()
        preloaded = null
        soloPlayOnLoad = play
        _snapshot.update { it.copy(loading = play) }
        soloJob = scope.launch {
            try {
                player.prepare(item, positionMs)
                loaded(item)
                _snapshot.update { it.copy(soloItemId = item.id, loading = false) }
                if (soloPlayOnLoad) player.play()
                soloPreload()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("could not load '${item.title}' while alone: ${e.message}")
                loadedItemId = null
                _snapshot.update { it.copy(loading = false) }
                loadFailed(item, e)
            }
        }
    }

    /** While alone, keep the gapless successor equal to the song after the one this device is on. */
    private fun soloPreload() {
        val s = state
        val mine = _snapshot.value.soloItemId
        val wanted = if (solo && s != null && mine != null && mine == loadedItemId && s.repeat != "one") {
            val at = s.queue.indexOfFirst { it.id == mine }
            if (at >= 0) s.queue.getOrNull(at + 1) else null
        } else {
            null
        }
        if (wanted == preloaded) return
        preloaded = wanted
        player.setNext(wanted)
    }

    // ------------------------------------------------------------------ handlers

    private fun onState(msg: ServerMessage.State) {
        state = msg.state
        _snapshot.update { it.copy(state = msg.state, members = msg.members, you = msg.you) }
        if (solo) {
            soloPreload() // the queue may have changed under us
            return
        }

        // Same or older epoch: we already follow this room (e.g. the queue changed). Nothing to do.
        if (msg.state.epoch <= handledEpoch) {
            if (startedAtServer != null) syncPreload() // e.g. a track was added after the current one
            return
        }

        when (msg.state.phase) {
            // A prepare message follows; it starts the barrier
            "preparing" -> Unit
            "idle" -> {
                handledEpoch = msg.state.epoch
                cancelPlayback()
                player.stop()
                loadedItemId = null
                preloaded = null
            }
            "paused" -> {
                handledEpoch = msg.state.epoch
                cancelPlayback()
                val item = msg.state.current ?: return
                log("catching up: paused at ${msg.state.positionMs}ms")
                startJob = scope.launch { loadPaused(item, msg.state.positionMs) }
            }
            "playing" -> {
                handledEpoch = msg.state.epoch
                cancelPlayback()
                val item = msg.state.current ?: return
                if (loadedItemId == item.id) {
                    // Reconnected while already on this item: keep playing, only realign
                    log("resyncing without reloading")
                    startJob = scope.launch { resumeLoaded(item, msg.state.startedAt) }
                } else {
                    log("catching up: room is playing")
                    startJob = scope.launch { catchUpPlaying(item, msg.state.startedAt) }
                }
            }
        }
        if (startedAtServer != null) syncPreload() // the queue may have changed
    }

    /** Applies a change the server announced without sending the whole state again. */
    private fun updateRoom(change: (RoomState) -> RoomState) {
        val current = state ?: return
        val changed = change(current)
        state = changed
        _snapshot.update { it.copy(state = changed) }
    }

    private fun onPrepare(msg: ServerMessage.Prepare) {
        if (solo) {
            updateRoom { it.copy(phase = "preparing", index = msg.index, epoch = msg.epoch, positionMs = msg.seekToMs) }
            return
        }
        if (msg.epoch < handledEpoch) return
        val by = msg.by
        if (by != null && by != _snapshot.value.you && msg.epoch != handledEpoch) {
            _events.tryEmit(RoomEvent.Skipped(by, msg.item.title))
        }
        if (msg.epoch == handledEpoch) {
            // The server repeats the prepare to a device that reconnected mid-barrier
            if (prepareJob?.isActive == true) return
            if (loadedItemId == msg.item.id) {
                send(Protocol.ready(msg.epoch))
                return
            }
        }
        if (msg.epoch != handledEpoch) recoveries = 0
        handledEpoch = msg.epoch
        cancelPlayback()
        loadedItemId = null
        preloaded = null
        val epoch = msg.epoch
        prepareJob = scope.launch {
            try {
                val t0 = nowMs()
                player.prepare(msg.item, msg.seekToMs)
                loaded(msg.item)
                log("prepared '${msg.item.title}' in ${nowMs() - t0}ms, reporting ready (epoch $epoch)")
                send(Protocol.ready(epoch))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("prepare failed: ${e.message}")
                send(Protocol.resolveFailed(epoch, e.message))
                loadFailed(msg.item, e)
            }
        }
    }

    private fun onStart(msg: ServerMessage.Start) {
        if (solo) {
            updateRoom { it.copy(phase = "playing", epoch = msg.epoch, positionMs = msg.positionMs, startedAt = msg.startAt - msg.positionMs) }
            return
        }
        if (msg.epoch < handledEpoch) return
        val waitForOwnPrepare = msg.epoch == handledEpoch && prepareJob?.isActive == true
        handledEpoch = msg.epoch
        // The server announces the start with this message only, so the UI's copy of the phase moves here
        updateRoom { it.copy(phase = "playing", epoch = msg.epoch, positionMs = msg.positionMs, startedAt = msg.startAt - msg.positionMs) }
        // Keep our own prepare running: a slow device still needs to finish loading
        startJob?.cancel()
        driftJob?.cancel()
        clearPendingAdopt()
        startedAtServer = null
        player.pause()

        val item = state?.current
        startJob = scope.launch {
            if (waitForOwnPrepare) prepareJob?.join()
            if (loadedItemId == null || (item != null && loadedItemId != item.id)) {
                // Missed the prepare (e.g. reconnected): load whatever the room is on now
                if (item == null) return@launch
                loadPaused(item, msg.positionMs)
            }
            if (loadedItemId == null) return@launch // could not load; sit this one out
            runStart(msg.startAt, msg.positionMs)
        }
    }

    private fun onPause(msg: ServerMessage.Pause) {
        if (solo) {
            updateRoom { it.copy(phase = "paused", epoch = msg.epoch, positionMs = msg.positionMs) }
            return
        }
        if (msg.epoch < handledEpoch) return
        handledEpoch = msg.epoch
        val by = msg.by
        if (by != null && by != _snapshot.value.you) _events.tryEmit(RoomEvent.Paused(by))
        updateRoom { it.copy(phase = "paused", epoch = msg.epoch, positionMs = msg.positionMs) }
        cancelPlayback()
        val item = state?.current
        startJob = scope.launch {
            if (loadedItemId != null) {
                player.seekTo(msg.positionMs)
            } else if (item != null) {
                loadPaused(item, msg.positionMs)
            }
        }
    }

    /**
     * The room moved on to the next item. A device that already did so keeps playing, one that is about
     * to do so waits for its player, and anything else loads the item like a late joiner.
     */
    private fun onAdvance(msg: ServerMessage.Advance) {
        if (solo) {
            updateRoom { it.copy(index = msg.index, epoch = msg.epoch, startedAt = msg.startedAt, positionMs = 0, phase = "playing") }
            return
        }
        if (msg.epoch <= handledEpoch) return
        val current = state ?: return
        val item = current.queue.getOrNull(msg.index) ?: return
        handledEpoch = msg.epoch
        recoveries = 0
        val advanced = current.copy(index = msg.index, epoch = msg.epoch, startedAt = msg.startedAt, positionMs = 0, phase = "playing")
        state = advanced
        _snapshot.update { it.copy(state = advanced) }

        when {
            loadedItemId == item.id -> adopt(msg.startedAt)
            preloaded?.id == item.id -> {
                // Our player is still finishing the previous item and will move on within moments
                driftJob?.cancel()
                startedAtServer = null
                pendingAdopt = PendingAdopt(item.id, msg.startedAt)
                advanceJob?.cancel()
                advanceJob = scope.launch {
                    delay(ADVANCE_WAIT_MS)
                    val stuck = pendingAdopt ?: return@launch
                    log("player did not advance in time, loading the item")
                    pendingAdopt = null
                    cancelPlayback()
                    startJob = scope.launch { catchUpPlaying(item, stuck.startedAt) }
                }
            }
            else -> {
                cancelPlayback()
                startJob = scope.launch { catchUpPlaying(item, msg.startedAt) }
            }
        }
    }

    /** The player switched to the preloaded item by itself. */
    private suspend fun onLocalAdvance() {
        val item = preloaded ?: return
        preloaded = null
        loadedItemId = item.id
        if (solo) {
            _snapshot.update { it.copy(soloItemId = item.id) }
            soloPreload()
            return
        }
        val pending = pendingAdopt
        if (pending != null && pending.itemId == item.id) {
            adopt(pending.startedAt)
            return
        }
        if (startedAtServer == null) return // not following the room in sync, nothing to report

        val epoch = handledEpoch
        driftJob?.cancel()
        startedAtServer = null // the position restarted at zero: the old start time no longer applies
        log("advanced locally to '${item.title}'")

        advanceJob?.cancel()
        advanceJob = scope.launch {
            delay(ADVANCE_REPORT_DELAY_MS) // let the position settle so the reported start is accurate
            if (handledEpoch != epoch || loadedItemId != item.id) return@launch // the server answered or moved on
            val startedAt = clock.toServer(nowMs()) - player.positionMs()
            if (player.isPlaying()) send(Protocol.advanced(epoch, item.id, startedAt))
            // The server normally answers with an advance message; if it does not (offline), follow our own clock
            delay(ADVANCE_WAIT_MS)
            if (handledEpoch == epoch && startedAtServer == null && loadedItemId == item.id) {
                log("no answer from the room, following the local start")
                adopt(clock.toServer(nowMs()) - player.positionMs())
            }
        }
    }

    /** Follow the room's clock for the item the player is on right now. */
    private fun adopt(startedAt: Long) {
        clearPendingAdopt()
        advanceJob?.cancel()
        startedAtServer = startedAt
        startDriftLoop()
        syncPreload()
        log("following '${state?.current?.title}' from server time $startedAt")
    }

    private fun clearPendingAdopt() {
        pendingAdopt = null
        advanceJob?.cancel()
    }

    /** Keep the player's gapless successor equal to the item after the current one, while following the room. */
    private fun syncPreload() {
        val s = state
        // Repeating one item is not gapless: it ends and the server starts it over through a barrier
        val following = startedAtServer != null && s != null && s.current?.id == loadedItemId && s.repeat != "one"
        val wanted = if (following) s?.queue?.getOrNull(s.index + 1) else null
        if (wanted == preloaded) return
        preloaded = wanted
        player.setNext(wanted)
    }

    /**
     * The stream broke while we were playing in sync. Reload it and rejoin at the position the room
     * has reached, exactly like a late joiner. Gives up after a few attempts per epoch.
     */
    private fun onPlayerError(error: Exception) {
        val startedAt = startedAtServer ?: return // not playing in sync: prepare deals with its own errors
        val item = state?.current ?: return
        if (++recoveries > MAX_RECOVERIES_PER_EPOCH) {
            log("player error, giving up after $MAX_RECOVERIES_PER_EPOCH recoveries: ${error.message}")
            // Silent while the room plays on: play tries again (see catchUp)
            startedAtServer = null
            loadedItemId = null
            loadFailed(item, error)
            return
        }
        log("player error, recovering (#$recoveries): ${error.message}")
        cancelPlayback()
        startJob = scope.launch { catchUpPlaying(item, startedAt) }
    }

    // ------------------------------------------------------------------ playback

    private suspend fun loadPaused(item: QueueItem, positionMs: Long) {
        try {
            preloaded = null // preparing replaces the whole playlist
            player.prepare(item, positionMs)
            loaded(item)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log("load failed: ${e.message}")
            loadedItemId = null
            loadFailed(item, e)
        }
    }

    private fun loaded(item: QueueItem) {
        loadedItemId = item.id
        reportedFailure = null
    }

    /** Tells the person, once for each item, that this device could not load it: the room may play on without it. */
    private fun loadFailed(item: QueueItem, error: Exception) {
        if (reportedFailure == item.id) return
        reportedFailure = item.id
        _events.tryEmit(RoomEvent.LoadFailed(item.title, LoadFailure.of(error)?.reason))
    }

    /**
     * Play was pressed while the room plays a song this device does not have (it could not load it, or gave up on a
     * broken stream): load it again and join in where the room is, instead of pressing play on an empty player.
     * Returns false when this device has the song, so that play just resumes it.
     */
    fun catchUp(): Boolean {
        if (solo || loadedItemId != null) return false
        val s = state ?: return false
        val item = s.current ?: return false
        if (s.phase != "playing") return false
        scope.launch {
            if (solo || loadedItemId != null || startJob?.isActive == true || prepareJob?.isActive == true) return@launch
            reportedFailure = null // a new try by hand is told about again if it fails
            log("play pressed with nothing loaded, catching up with the room")
            startJob = scope.launch { catchUpPlaying(item, s.startedAt) }
        }
        return true
    }

    /** The item is already loaded (e.g. after a reconnect): realign to the room's clock and make sure it plays. */
    private suspend fun resumeLoaded(item: QueueItem, startedAt: Long) {
        if (!player.isPlaying() && !held) {
            val target = clock.toServer(nowMs()) - startedAt + seekCostMs
            player.seekTo(target.coerceAtLeast(0))
            player.play()
        }
        loadedItemId = item.id
        adopt(startedAt)
    }

    /**
     * Join a room that is already playing: load, then start at whatever position it has reached.
     * If loading fails (typically no network yet) it tries again every few seconds until a newer
     * message cancels this job.
     */
    private suspend fun catchUpPlaying(item: QueueItem, startedAt: Long) {
        var attempt = 0
        while (true) {
            val guessed = clock.toServer(nowMs()) - startedAt + CATCH_UP_LOAD_GUESS_MS
            loadPaused(item, guessed.coerceAtLeast(0))
            if (loadedItemId != null) break
            if (++attempt >= CATCH_UP_MAX_ATTEMPTS) {
                log("giving up loading '${item.title}' after $attempt attempts")
                return
            }
            delay(CATCH_UP_RETRY_MS)
        }
        val targetServer = clock.toServer(nowMs()) + CATCH_UP_LEAD_MS
        runStart(targetServer, (targetServer - startedAt).coerceAtLeast(0))
    }

    /** Play position [positionMs] at server time [startAtServer]; if that moment has passed, skip ahead. */
    private suspend fun runStart(startAtServer: Long, positionMs: Long) {
        val startLocal = clock.toLocal(startAtServer)
        if (startLocal - nowMs() > MIN_TIME_TO_ALIGN_MS) {
            player.seekTo(positionMs + startBiasMs)
            val wait = startLocal - nowMs()
            if (wait > 0) delay(wait)
            if (!held) player.play()
            log("${if (held) "held, not playing" else "play()"} at scheduled time, position $positionMs")
        } else {
            val late = nowMs() - startLocal
            val target = positionMs + late.coerceAtLeast(0) + seekCostMs + startBiasMs
            player.seekTo(target)
            if (!held) player.play()
            log("${if (held) "held, not playing" else "play()"} late by ${late}ms, skipped to $target")
        }
        drift.reset()
        player.setSpeed(1f)
        startedAtServer = startAtServer - positionMs
        learnBias = !held
        startDriftLoop()
        syncPreload()
    }

    private fun startDriftLoop() {
        driftJob?.cancel()
        driftJob = scope.launch {
            var settleUntil = 0L
            var tick = 0
            var playingTicks = 0
            filter.reset(nowMs())
            while (isActive) {
                delay(DRIFT_TICK_MS)
                val started = startedAtServer ?: break
                if (!player.isPlaying()) {
                    playingTicks = 0
                    _snapshot.update { it.copy(driftMs = null) }
                    // Readings from before a stall say nothing about the position after it
                    filter.reset(nowMs(), _snapshot.value.speed)
                    continue // buffering or paused: nothing meaningful to measure
                }
                if (++playingTicks >= HEALTHY_TICKS) recoveries = 0
                val now = nowMs()
                val expected = clock.toServer(now) - started + trimMs
                val driftMs = player.positionMs() - expected
                _snapshot.update { it.copy(driftMs = driftMs) }
                if (now < settleUntil) continue // let a recent seek settle before measuring again
                filter.add(now, driftMs)
                val smoothed = filter.estimate(now) ?: continue
                if (++tick % LOG_EVERY_TICKS == 0) {
                    log("drift=${driftMs}ms smoothed=${smoothed}ms offset=${clock.offsetMs().toLong()}ms rtt=${clock.bestRttMs()?.toLong()}ms")
                }
                if (learnBias && filter.isFull) learnStartBias()
                if (!correctionEnabled) continue
                val trusted = if (abs(smoothed) > drift.seekThresholdMs) filter.hasLargeDriftEvidence else filter.isFull
                if (!trusted) continue

                when (val action = drift.decide(smoothed)) {
                    DriftAction.None -> Unit
                    is DriftAction.SetSpeed -> {
                        player.setSpeed(action.factor)
                        filter.setSpeed(now, action.factor)
                        _snapshot.update { it.copy(speed = action.factor) }
                        log("drift=${smoothed}ms (smoothed) -> speed ${action.factor}")
                    }
                    DriftAction.Seek -> {
                        val before = nowMs()
                        // Aim a little ahead: the seek itself takes time
                        val target = clock.toServer(before) - started + seekCostMs + trimMs
                        learnBias = false // a corrective seek muddies what the plain start looked like
                        player.seekTo(target)
                        seekCostMs = (nowMs() - before).coerceIn(50, 1000)
                        player.setSpeed(1f)
                        filter.reset(nowMs())
                        _snapshot.update { it.copy(speed = 1f) }
                        settleUntil = nowMs() + SETTLE_AFTER_SEEK_MS
                        log("drift=${smoothed}ms (smoothed) -> seek to $target (took ${seekCostMs}ms)")
                    }
                }
            }
        }
    }

    /** The first full window after a plain start shows how far off that start was; fold it into the bias. */
    private fun learnStartBias() {
        learnBias = false
        val residual = filter.uncorrectedMean() ?: return
        val updated = (startBiasMs - residual * BIAS_LEARNING_RATE).toLong().coerceIn(-MAX_BIAS_MS, MAX_BIAS_MS)
        log("start was ${residual.toLong()}ms off, start bias $startBiasMs -> ${updated}ms")
        startBiasMs = updated
        onStartBiasLearned?.invoke(updated)
    }

    private fun cancelPlayback() {
        learnBias = false
        prepareJob?.cancel()
        startJob?.cancel()
        driftJob?.cancel()
        clearPendingAdopt()
        startedAtServer = null
        player.pause()
        player.setSpeed(1f)
        drift.reset()
        _snapshot.update { it.copy(driftMs = null, speed = 1f) }
    }

    private companion object {
        /** Below this much time to the scheduled start there is no point in seeking first. */
        const val MIN_TIME_TO_ALIGN_MS = 120L
        const val DRIFT_TICK_MS = 500L
        const val LOG_EVERY_TICKS = 2 // every second
        const val SETTLE_AFTER_SEEK_MS = 1500L
        const val CATCH_UP_LOAD_GUESS_MS = 2000L
        const val CATCH_UP_LEAD_MS = 400L
        const val CATCH_UP_RETRY_MS = 5000L
        const val CATCH_UP_MAX_ATTEMPTS = 60 // about five minutes plus the time each attempt takes

        /** Continuous playing this long counts as healthy again: earlier recoveries are forgotten. */
        const val HEALTHY_TICKS = 60
        const val MAX_RECOVERIES_PER_EPOCH = 5
        const val BIAS_LEARNING_RATE = 0.8
        const val MAX_BIAS_MS = 800L

        /** After moving to the next item by itself, wait this long before reporting when it started. */
        const val ADVANCE_REPORT_DELAY_MS = 1000L

        /** How long to wait for the room's answer, or for our own player, around a gapless advance. */
        const val ADVANCE_WAIT_MS = 4000L

        /** Like most players: "previous" restarts the song unless it has only just begun. */
        const val PREV_RESTARTS_AFTER_MS = 3000L
    }
}
