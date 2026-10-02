package app.unison

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import app.unison.sync.ClockSync
import app.unison.sync.Connection
import app.unison.sync.GroupSession
import app.unison.sync.LocalSession
import app.unison.sync.QueueItem
import app.unison.sync.Protocol
import app.unison.sync.QueueFile
import app.unison.sync.Queues
import app.unison.sync.RoomClient
import app.unison.sync.Sleep
import app.unison.sync.SleepTimer
import app.unison.sync.TrackRef
import app.unison.sync.ServerMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Lives in the playback service so the room connection survives the activity. While joined, the
 * room decides what plays; while not joined, the player plays the personal queue, like any music player.
 */
class GroupController(
    private val context: Context,
    private val exo: ExoPlayer,
    private val prefs: SharedPreferences,
    private val queueFile: QueueFile,
    /** Up to [Int] songs to carry on with after [String] (a video id), leaving out the ids given. */
    private val moreLike: suspend (String, Set<String>, Int) -> List<TrackRef> = { _, _, _ -> emptyList() },
) {
    // Main thread: ExoPlayer must be used there, and the session only does light work
    private var scope = newScope()
    private val port = ExoPlayerPort(exo)
    private val clock = ClockSync()

    /** Lives as long as this controller; [scope] is replaced each time a room is left. */
    private val ownScope = newScope()

    /** Saving the queue is disk work, so it is done off the main thread, in order. */
    private val writer = Executors.newSingleThreadExecutor()

    /** The queue that plays outside a room; it comes back after a restart, paused. */
    val local = LocalSession(
        ownScope,
        port,
        queueFile.read(),
        persist = { saved -> writer.execute { runCatching { queueFile.write(saved) } } },
        problem = { text -> _errors.tryEmit(ServerMessage.Error("unplayable", text)) },
        log = { EventLog.d("local", it) },
        onQueueEnd = ::autoplay,
    )

    private var autoplayJob: Job? = null
    private var radioJob: Job? = null

    /** Stops this device after a while, or when the song is over; the fade is the player's own volume. */
    val sleep = SleepTimer(
        ownScope,
        wallClock = System::currentTimeMillis,
        stop = ::stopForSleep,
        fade = { exo.volume = it },
        pauseAtSongEnd = { exo.setPauseAtEndOfMediaItems(it) },
    )

    private var client: RoomClient? = null
    private var session: GroupSession? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /** What the UI shows: the room as last announced, plus the connection to it, and the personal queue for outside a room. */
    data class View(
        val roomCode: String? = null,
        val connection: Connection? = null,
        val snapshot: GroupSession.Snapshot = GroupSession.Snapshot(),
        val local: LocalSession.Snapshot = LocalSession.Snapshot(),
    )

    private val _view = MutableStateFlow(View(local = local.snapshot.value))
    val view: StateFlow<View> = _view.asStateFlow()

    /** Errors the server reports to this device, e.g. a track nobody could play. */
    private val _errors = MutableSharedFlow<ServerMessage.Error>(extraBufferCapacity = 8)
    val errors: SharedFlow<ServerMessage.Error> = _errors.asSharedFlow()

    /** Something another member did that moved this device, with their name already looked up. */
    data class Notice(val kind: String, val by: String, val title: String? = null)

    private val _notices = MutableSharedFlow<Notice>(extraBufferCapacity = 8)
    val notices: SharedFlow<Notice> = _notices.asSharedFlow()

    /** A member's picture, as base64; [data] is null when they have none (any more). */
    data class Avatar(val id: String, val data: String?)

    private val _avatars = MutableSharedFlow<Avatar>(extraBufferCapacity = 64)
    val avatars: SharedFlow<Avatar> = _avatars.asSharedFlow()

    /** The latest picture of each member, for a screen that comes back after pictures arrived. */
    private val pictures = java.util.concurrent.ConcurrentHashMap<String, String>()

    fun picturesSeen(): List<Avatar> = pictures.map { Avatar(it.key, it.value) }

    /** The picture this device shows the room as its own, as base64 of a small JPEG; null for none. Kept across restarts. */
    fun setAvatar(data: String?) {
        prefs.edit().apply { if (data == null) remove(KEY_AVATAR) else putString(KEY_AVATAR, data) }.apply()
        client?.setAvatar(data)
    }

    var roomCode: String? = null
        private set

    val isActive: Boolean get() = client != null

    /** The connection was let go of after a long idle spell, see [suspendRoom]. */
    private var suspended = false

    /** Commands given while [suspended], sent once the connection is back. */
    private val pending = mutableListOf<String>()

    /** Songs are played with their picture; this device's choice, remembered across runs. */
    var videoMode: Boolean = prefs.getBoolean(KEY_VIDEO, false)
        private set

    init {
        port.setVideoMode(videoMode)
        local.attach()
        // After the personal queue's own listener: when the last song ends it must see the timer still set
        exo.addListener(object : Player.Listener {
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (reason == Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM) sleep.songEnded()
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED) sleep.songEnded()
            }
        })
        ownScope.launch { local.snapshot.collect { publish() } }
    }

    /**
     * The personal queue ran out. Unless the person turned it off, it carries on with songs like the last
     * one, so the music does not just stop. Nothing happens without a network, in a room, or when they
     * asked for something else in the meantime.
     */
    private fun autoplay(last: QueueItem) {
        if (!autoplayOn || session != null || autoplayJob?.isActive == true || sleep.state.value == Sleep.SongEnd) return
        autoplayJob = ownScope.launch {
            try {
                val more = moreLike(last.videoId, local.snapshot.value.queue.map { it.videoId }.toSet(), AUTOPLAY_COUNT)
                if (more.isEmpty() || session != null || !local.snapshot.value.finished) return@launch
                EventLog.d("local", "autoplay adds ${more.size} songs like '${last.title}'")
                // A queue that has grown long by carrying on is started afresh rather than filling up
                if (local.snapshot.value.queue.size > AUTOPLAY_RESTART_AT) local.clear()
                local.add(more, next = false)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                EventLog.d("local", "autoplay found nothing: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    /**
     * A song was started on its own, from a search or a shelf. Like YouTube Music, the queue fills with songs like
     * it, so skipping works at once and the music carries on. Nothing is added when autoplay is off, in a room, or
     * when the person has changed the queue by the time the songs arrive.
     */
    fun requestRadio(videoId: String) {
        radioJob?.cancel()
        if (!autoplayOn || session != null) return
        radioJob = ownScope.launch {
            try {
                val more = moreLike(videoId, setOf(videoId), RADIO_COUNT)
                val queue = local.snapshot.value.queue
                if (more.isEmpty() || session != null || queue.singleOrNull()?.videoId != videoId) return@launch
                EventLog.d("local", "radio adds ${more.size} songs like $videoId")
                local.add(more, next = false)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                EventLog.d("local", "no radio for $videoId: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    /** The sleep timer ran out. In a room only this device stops: it carries on alone, paused, and the room plays on. */
    private fun stopForSleep() {
        val s = session
        if (s == null) {
            local.pause()
            return
        }
        if (!s.isSolo) s.goSolo()
        s.soloPause()
    }

    /** Whether the music carries on by itself when the queue runs out. */
    var autoplayOn: Boolean
        get() = prefs.getBoolean(KEY_AUTOPLAY, true)
        set(value) = prefs.edit().putBoolean(KEY_AUTOPLAY, value).apply()

    fun setVideoMode(on: Boolean) {
        videoMode = on
        prefs.edit().putBoolean(KEY_VIDEO, on).apply()
        port.setVideoMode(on)
        EventLog.d("video", "picture ${if (on) "on" else "off"}")
    }

    /** The picture is on screen; when it is not, it is neither downloaded nor decoded. */
    fun setVideoVisible(visible: Boolean) = port.setVideoVisible(visible)

    /** Where the player draws the picture, or null to let go of the screen. */
    fun attachVideoSurface(surface: Surface?) {
        if (surface == null) exo.clearVideoSurface() else exo.setVideoSurface(surface)
    }

    /** Per-device latency correction in ms, see [GroupSession.trimMs]. */
    var trimMs: Long = prefs.getLong(KEY_TRIM_MS, 0L)
        private set

    /** [create] says whether the code was just made (true) or given to this device (false): a mistyped code must not open a room. */
    fun join(baseUrl: String, code: String, name: String, create: Boolean) {
        stopFollowing()
        local.detach()
        val id = deviceId()
        val now = { SystemClock.elapsedRealtime() }
        val log = { message: String -> EventLog.d("sync", message) }

        val newSession = GroupSession(scope, port, clock, now, { text -> client?.send(text) }, log)
        newSession.trimMs = trimMs
        newSession.startBiasMs = prefs.getLong(KEY_START_BIAS_MS, 0L)
        newSession.onStartBiasLearned = { prefs.edit().putLong(KEY_START_BIAS_MS, it).apply() }
        val newClient = RoomClient(baseUrl, code, id, name, scope, clock, now, log, Config.authHeaders, create)
        newClient.onMessage = {
            if (it is ServerMessage.Error) _errors.tryEmit(it)
            newSession.onMessage(it)
        }
        newClient.onAvatar = { memberId, _, data ->
            if (data == null) pictures.remove(memberId) else pictures[memberId] = data
            _avatars.tryEmit(Avatar(memberId, data))
        }
        newClient.setAvatar(prefs.getString(KEY_AVATAR, null))
        newClient.onConnected = {
            newSession.onReconnected()
            scope.launch { flushPending(newClient) }
        }

        session = newSession
        client = newClient
        suspended = false
        pending.clear()
        roomCode = code.uppercase()
        publish()
        scope.launch { newSession.snapshot.collect { publish() } }
        // Listening alone is remembered, so that a restart brings this device back to it instead of into the room's music
        scope.launch {
            newSession.snapshot.map { it.solo to it.soloItemId }.distinctUntilChanged().collect { (solo, itemId) ->
                prefs.edit().putBoolean(KEY_ROOM_SOLO, solo).putString(KEY_ROOM_SOLO_ITEM, itemId).apply()
            }
        }
        scope.launch {
            while (true) {
                prefs.edit().putLong(KEY_LAST_ACTIVE, System.currentTimeMillis()).apply()
                delay(ACTIVE_STAMP_MS)
            }
        }
        scope.launch {
            newSession.events.collect { event ->
                val members = newSession.snapshot.value.members
                val name = { id: String -> members.firstOrNull { it.id == id }?.name.orEmpty() }
                _notices.tryEmit(
                    when (event) {
                        is GroupSession.RoomEvent.Paused -> Notice("paused", name(event.byId))
                        is GroupSession.RoomEvent.Skipped -> Notice("skipped", name(event.byId), event.title)
                    },
                )
            }
        }
        scope.launch {
            newClient.connection.collect { connection ->
                publish()
                // Turned away for good (the room is full, gone, or the owner removed this device): back to the personal queue.
                // Posted, because leaving cancels the scope this is running in.
                if (connection == Connection.REFUSED) Handler(Looper.getMainLooper()).post { leave() }
            }
        }
        prefs.edit().putString(KEY_ROOM_CODE, roomCode).putString(KEY_ROOM_NAME, name).apply()
        EventLog.d("sync", "joining room $roomCode as '$name' ($id)")
        newClient.start()
        watchNetwork(newClient)
    }

    /** Reconnect at once when the network comes back or changes, instead of waiting out the backoff. */
    private fun watchNetwork(target: RoomClient) {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        var current: Network? = null
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val changed = current != null && current != network
                current = network
                if (changed || target.connection.value != Connection.CONNECTED) {
                    EventLog.d("sync", "network available, reconnecting now")
                    target.reconnectNow()
                }
            }

            override fun onLost(network: Network) {
                if (current == network) current = null
            }
        }
        try {
            cm.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (e: RuntimeException) {
            EventLog.d("sync", "cannot watch the network: ${e.message}")
        }
    }

    /** Leave on the user's request: the room is forgotten and will not be rejoined automatically. */
    fun leave() {
        prefs.edit().remove(KEY_ROOM_CODE).remove(KEY_ROOM_SOLO).remove(KEY_ROOM_SOLO_ITEM).apply()
        stopFollowing()
    }

    /**
     * Called when the service starts. A room is only rejoined when the system killed the process while this
     * device was in it a moment ago, and listening alone comes back as such, paused. Opening the app any other
     * time starts outside a room, on the personal queue.
     */
    fun recoverRoom() {
        val code = prefs.getString(KEY_ROOM_CODE, null) ?: return
        val idleMs = System.currentTimeMillis() - prefs.getLong(KEY_LAST_ACTIVE, 0)
        if (idleMs !in 0..RECOVERY_WINDOW_MS) {
            EventLog.d("sync", "not rejoining $code, it was left ${idleMs / 1000}s ago")
            prefs.edit().remove(KEY_ROOM_CODE).apply()
            return
        }
        // Read before joining: joining writes the listening mode of the new session over these
        val alone = prefs.getBoolean(KEY_ROOM_SOLO, false)
        val aloneOn = prefs.getString(KEY_ROOM_SOLO_ITEM, null)
        val name = prefs.getString(KEY_ROOM_NAME, null) ?: android.os.Build.MODEL
        EventLog.d("sync", "rejoining $code after the process was killed${if (alone) ", on my own" else ""}")
        join(Config.SERVER, code, name, create = false)
        if (alone) session?.restoreSolo(aloneOn)
    }

    /** Change the display name in the current room without interrupting playback. */
    fun rename(name: String) {
        prefs.edit().putString(KEY_ROOM_NAME, name).apply()
        client?.rename(name)
    }

    fun savedName(): String? = prefs.getString(KEY_ROOM_NAME, null)
    fun savedCode(): String? = prefs.getString(KEY_ROOM_CODE, null)

    /** [deliberate]: the person left, so the room is told and an owner hands it over; otherwise the process is just going away. */
    private fun stopFollowing(deliberate: Boolean = true) {
        if (client == null) return
        EventLog.d("sync", "leaving room $roomCode")
        networkCallback?.let { runCatching { context.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it) } }
        networkCallback = null
        if (deliberate) client?.leave() else client?.close()
        session?.close()
        client = null
        session = null
        roomCode = null
        suspended = false
        pending.clear()
        pictures.clear()
        scope.cancel()
        scope = newScope()
        local.attach() // the personal queue gets the player back, paused where it was
        publish()
    }

    private fun publish() {
        _view.value = View(roomCode, client?.connection?.value, session?.snapshot?.value ?: GroupSession.Snapshot(), local.snapshot.value)
    }

    /** Sends a command to the room. If the connection was let go of, it is brought back and the command goes when it is up. */
    fun send(text: String): Boolean {
        if (suspended) {
            pending += text
            resumeRoom()
            return true
        }
        return client?.send(text) ?: false
    }

    /**
     * Nobody has listened or looked for a long while: close the connection, because its pings keep the radio
     * awake all day. The room, this device's place in it and whether it listens alone are all kept.
     */
    fun suspendRoom() {
        val c = client ?: return
        if (suspended) return
        suspended = true
        EventLog.d("sync", "nobody is listening or looking, letting go of the connection to $roomCode")
        c.close()
    }

    /** Someone is looking again, or asked for something: connect again. */
    fun resumeRoom() {
        if (!suspended) return
        suspended = false
        EventLog.d("sync", "connecting to $roomCode again")
        client?.start()
    }

    private fun flushPending(target: RoomClient) {
        if (target !== client) return
        pending.forEach { target.send(it) }
        pending.clear()
    }

    /**
     * Play button. If the room is playing and only this device stopped (a phone call, another app took
     * audio focus), resume just this device and let the drift correction catch it up; restarting the
     * whole room would interrupt everyone else.
     */
    fun requestPlay(resumeLocally: () -> Unit) {
        if (phase() == "playing" && !exo.playWhenReady) resumeLocally() else requestPlay()
    }

    /** Listening on this device alone: the room does not move it, and its buttons do not move the room. */
    val isSolo: Boolean get() = session?.isSolo == true

    /** Stop following the room and carry on alone. */
    fun goSolo() {
        session?.goSolo()
    }

    /** Follow the room again. */
    fun rejoin() {
        session?.rejoin()
    }

    /** The room stopped and this device wants to go on: leave the room's transport and resume. */
    fun keepPlaying() {
        val s = session ?: return
        s.goSolo()
        s.soloPlay()
    }

    // Outside a room the buttons drive the personal queue; in a room they act on the room, or on this device alone
    fun requestPlay(): Boolean = act({ it.play() }, { it.soloPlay() }) { send(Protocol.play()) }
    fun requestPause(): Boolean = act({ it.pause() }, { it.soloPause() }) { send(Protocol.pause()) }
    fun requestNext(): Boolean = act({ it.next() }, { it.soloNext() }) { send(Protocol.next()) }
    fun requestPrev(): Boolean = act({ it.prev() }, { it.soloPrev() }) { send(Protocol.prev()) }
    fun requestSeek(positionMs: Long): Boolean = act({ it.seek(positionMs) }, { it.soloSeek(positionMs) }) { send(Protocol.seek(positionMs)) }
    fun requestJump(itemId: String): Boolean = act({ it.jump(itemId) }, { it.soloJump(itemId) }) { send(Protocol.jump(itemId)) }

    /** The queue is the room's in a room, even while listening alone, and the personal one outside. */
    private inline fun onQueue(onLocal: (LocalSession) -> Unit, onRoom: () -> Boolean): Boolean {
        if (session == null) {
            onLocal(local)
            return true
        }
        return onRoom()
    }

    fun requestClearQueue() = onQueue({ it.clear() }) { send(Protocol.queueClear()) }
    fun requestShuffle() = onQueue({ it.shuffle() }) { send(Protocol.queueShuffle()) }
    fun requestRepeat(mode: String) = onQueue({ it.setRepeat(mode) }) { send(Protocol.repeat(mode)) }
    fun requestAddMany(tracks: List<TrackRef>, playNext: Boolean) = onQueue({ it.add(tracks, playNext) }) {
        // What is waiting in the room's queue is not added twice
        val fresh = Queues.fresh(tracks, queue(), session?.snapshot?.value?.state?.index ?: 0)
        fresh.isEmpty() || send(Protocol.queueAddMany(fresh, playNext))
    }
    fun requestSwap(itemId: String, track: TrackRef) = onQueue({ it.swap(itemId, track) }) { send(Protocol.queueSwap(itemId, track)) }
    fun requestRemove(itemId: String) = onQueue({ it.remove(itemId) }) { send(Protocol.queueRemove(itemId)) }
    fun requestMove(itemId: String, toIndex: Int) = onQueue({ it.move(itemId, toIndex) }) { send(Protocol.queueMove(itemId, toIndex)) }

    // Only meaningful in a room
    fun requestKick(memberId: String) = send(Protocol.kick(memberId))
    fun requestRoomName(name: String) = send(Protocol.roomName(name))
    fun requestRoomSettings(guestControl: String) = send(Protocol.roomSettings(guestControl))

    /** Runs the action for wherever the buttons act: outside a room, alone in a room, or on the room itself. */
    private inline fun act(onLocal: (LocalSession) -> Unit, onSolo: (GroupSession) -> Unit, onRoom: () -> Boolean): Boolean {
        val s = session
        return when {
            s == null -> {
                onLocal(local)
                true
            }
            s.isSolo -> {
                onSolo(s)
                true
            }
            else -> onRoom()
        }
    }

    /** The room's current queue, for callers that need item ids. */
    fun queue(): List<app.unison.sync.QueueItem> = session?.snapshot?.value?.state?.queue ?: emptyList()

    fun setTrim(ms: Long) {
        trimMs = ms.coerceIn(-MAX_TRIM_MS, MAX_TRIM_MS)
        prefs.edit().putLong(KEY_TRIM_MS, trimMs).apply()
        session?.trimMs = trimMs
        EventLog.d("sync", "latency trim ${trimMs}ms")
    }

    /** Diagnostics: turn drift correction off to observe the raw drift. */
    fun setCorrection(enabled: Boolean) {
        session?.correctionEnabled = enabled
        EventLog.d("sync", "drift correction ${if (enabled) "on" else "off"}")
    }

    data class PlayerInfo(
        val playing: Boolean,
        val buffering: Boolean,
        val positionMs: Long,
        val durationMs: Long,
        val videoWidth: Int = 0,
        val videoHeight: Int = 0,
        /** The picture is wanted but this song plays without one. */
        val noPicture: Boolean = false,
    )

    /** Snapshot of the local player for the UI; call on the main thread. */
    fun playerInfo(): PlayerInfo {
        // After a restart the queue is back but nothing is loaded: show where the song will resume
        val restored = if (roomCode == null) local.restoredPositionMs else null
        if (restored != null) {
            return PlayerInfo(playing = false, buffering = false, positionMs = restored, durationMs = local.snapshot.value.current?.durMs ?: 0)
        }
        return PlayerInfo(
            playing = exo.isPlaying,
            buffering = exo.playbackState == Player.STATE_BUFFERING,
            positionMs = exo.currentPosition.coerceAtLeast(0),
            durationMs = exo.duration.coerceAtLeast(0),
            videoWidth = exo.videoSize.width,
            videoHeight = exo.videoSize.height,
            noPicture = port.pictureMissing(),
        )
    }

    fun addPlayerListener(listener: Player.Listener) = exo.addListener(listener)
    fun removePlayerListener(listener: Player.Listener) = exo.removeListener(listener)

    /** Resume only this device's player, see [requestPlay]. */
    fun playLocally() = exo.play()

    /** Phase of the room as last announced by the server, or null when not joined. */
    fun phase(): String? = session?.snapshot?.value?.state?.phase

    /** One-line summary for the test UI. */
    fun describe(): String {
        val c = client ?: return "not in a room"
        val snap = session?.snapshot?.value
        val state = snap?.state
        val current = state?.current?.title ?: "-"
        return "room $roomCode ${c.connection.value} | ${snap?.members?.size ?: 0} member(s) | " +
            "phase=${state?.phase} epoch=${state?.epoch} queue=${state?.queue?.size ?: 0} | $current" +
            "${if (snap?.solo == true) " | ALONE" else ""}\n" +
            "drift=${snap?.driftMs?.let { "%+dms".format(it) } ?: "-"} speed=${snap?.speed} trim=${trimMs}ms " +
            "clockOffset=${clock.offsetMs().toLong()}ms rtt=${clock.bestRttMs()?.toLong() ?: "-"}ms"
    }

    fun release() {
        stopFollowing(deliberate = false) // keep the saved room so a restart soon after rejoins it
        local.save()
        ownScope.cancel()
        scope.cancel()
        // Let the last write of the queue finish
        writer.shutdown()
        writer.awaitTermination(2, TimeUnit.SECONDS)
    }

    /** Stable per-install id, so a reconnecting device replaces its own stale socket. */
    private fun deviceId(): String =
        prefs.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString(KEY_DEVICE_ID, it).apply()
        }

    private fun newScope() = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private companion object {
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_ROOM_CODE = "room_code"
        const val KEY_ROOM_NAME = "room_name"
        const val KEY_AVATAR = "avatar"
        const val KEY_ROOM_SOLO = "room_solo"
        const val KEY_ROOM_SOLO_ITEM = "room_solo_item"
        const val KEY_LAST_ACTIVE = "room_last_active"
        const val KEY_VIDEO = "video_mode"
        const val KEY_AUTOPLAY = "autoplay"
        const val AUTOPLAY_RESTART_AT = 150

        /** Songs added each time the queue runs out and the music carries on by itself. */
        const val AUTOPLAY_COUNT = 5

        /** Songs that follow one that was played on its own. */
        const val RADIO_COUNT = 20
        const val KEY_TRIM_MS = "trim_ms"
        const val KEY_START_BIAS_MS = "start_bias_ms"
        const val MAX_TRIM_MS = 1000L

        /** How often the time of the last sign of life is written down while in a room. */
        const val ACTIVE_STAMP_MS = 60_000L

        /** A room is rejoined after a restart only if this device was in it this recently. */
        const val RECOVERY_WINDOW_MS = 10 * 60_000L
    }
}
