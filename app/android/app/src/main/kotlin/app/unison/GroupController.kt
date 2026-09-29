package app.unison

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.os.SystemClock
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import app.unison.sync.ClockSync
import app.unison.sync.Connection
import app.unison.sync.GroupSession
import app.unison.sync.Protocol
import app.unison.sync.RoomClient
import app.unison.sync.TrackRef
import app.unison.sync.ServerMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Lives in the playback service so the room connection survives the activity. While joined, the
 * room decides what plays; while not joined, the player behaves as a plain local player.
 */
class GroupController(
    private val context: Context,
    private val exo: ExoPlayer,
    private val prefs: SharedPreferences,
) {
    // Main thread: ExoPlayer must be used there, and the session only does light work
    private var scope = newScope()
    private val port = ExoPlayerPort(exo)
    private val clock = ClockSync()

    private var client: RoomClient? = null
    private var session: GroupSession? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /** What the UI shows: the room as last announced, plus the connection to it. */
    data class View(
        val roomCode: String? = null,
        val connection: Connection? = null,
        val snapshot: GroupSession.Snapshot = GroupSession.Snapshot(),
    )

    private val _view = MutableStateFlow(View())
    val view: StateFlow<View> = _view.asStateFlow()

    /** Errors the server reports to this device, e.g. a track nobody could play. */
    private val _errors = MutableSharedFlow<ServerMessage.Error>(extraBufferCapacity = 8)
    val errors: SharedFlow<ServerMessage.Error> = _errors.asSharedFlow()

    /** Something another member did that moved this device, with their name already looked up. */
    data class Notice(val kind: String, val by: String, val title: String? = null)

    private val _notices = MutableSharedFlow<Notice>(extraBufferCapacity = 8)
    val notices: SharedFlow<Notice> = _notices.asSharedFlow()

    var roomCode: String? = null
        private set

    val isActive: Boolean get() = client != null

    /** Per-device latency correction in ms, see [GroupSession.trimMs]. */
    var trimMs: Long = prefs.getLong(KEY_TRIM_MS, 0L)
        private set

    fun join(baseUrl: String, code: String, name: String) {
        stopFollowing()
        val id = deviceId()
        val now = { SystemClock.elapsedRealtime() }
        val log = { message: String -> EventLog.d("sync", message) }

        val newSession = GroupSession(scope, port, clock, now, { text -> client?.send(text) }, log)
        newSession.trimMs = trimMs
        newSession.startBiasMs = prefs.getLong(KEY_START_BIAS_MS, 0L)
        newSession.onStartBiasLearned = { prefs.edit().putLong(KEY_START_BIAS_MS, it).apply() }
        val newClient = RoomClient(baseUrl, code, id, name, scope, clock, now, log, Config.authHeaders)
        newClient.onMessage = {
            if (it is ServerMessage.Error) _errors.tryEmit(it)
            newSession.onMessage(it)
        }
        newClient.onConnected = { newSession.onReconnected() }

        session = newSession
        client = newClient
        roomCode = code.uppercase()
        publish()
        scope.launch { newSession.snapshot.collect { publish() } }
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
        scope.launch { newClient.connection.collect { publish() } }
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
        prefs.edit().remove(KEY_ROOM_CODE).apply()
        stopFollowing()
    }

    /** Rejoin the room this device was in when the process last ran, e.g. after the system killed it. */
    fun rejoinSaved() {
        val code = prefs.getString(KEY_ROOM_CODE, null) ?: return
        val name = prefs.getString(KEY_ROOM_NAME, null) ?: android.os.Build.MODEL
        EventLog.d("sync", "rejoining saved room $code")
        join(Config.SERVER, code, name)
    }

    /** Change the display name in the current room without interrupting playback. */
    fun rename(name: String) {
        prefs.edit().putString(KEY_ROOM_NAME, name).apply()
        client?.rename(name)
    }

    fun savedName(): String? = prefs.getString(KEY_ROOM_NAME, null)
    fun savedCode(): String? = prefs.getString(KEY_ROOM_CODE, null)

    private fun stopFollowing() {
        if (client == null) return
        EventLog.d("sync", "leaving room $roomCode")
        networkCallback?.let { runCatching { context.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it) } }
        networkCallback = null
        client?.close()
        session?.close()
        client = null
        session = null
        roomCode = null
        scope.cancel()
        scope = newScope()
        publish()
    }

    private fun publish() {
        _view.value = View(roomCode, client?.connection?.value, session?.snapshot?.value ?: GroupSession.Snapshot())
    }

    fun send(text: String): Boolean = client?.send(text) ?: false

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

    // While alone the transport buttons act on this device only
    fun requestPlay(): Boolean = solo { it.soloPlay() } ?: send(Protocol.play())
    fun requestPause(): Boolean = solo { it.soloPause() } ?: send(Protocol.pause())
    fun requestNext(): Boolean = solo { it.soloNext() } ?: send(Protocol.next())
    fun requestPrev(): Boolean = solo { it.soloPrev() } ?: send(Protocol.prev())
    fun requestSeek(positionMs: Long): Boolean = solo { it.soloSeek(positionMs) } ?: send(Protocol.seek(positionMs))
    fun requestJump(itemId: String): Boolean = solo { it.soloJump(itemId) } ?: send(Protocol.jump(itemId))

    /** Runs [action] on the session when listening alone and reports it handled; null when following the room. */
    private inline fun solo(action: (GroupSession) -> Unit): Boolean? {
        val s = session?.takeIf { it.isSolo } ?: return null
        action(s)
        return true
    }
    fun requestClearQueue() = send(Protocol.queueClear())
    fun requestRepeat(mode: String) = send(Protocol.repeat(mode))
    fun requestAddMany(tracks: List<TrackRef>, playNext: Boolean) = send(Protocol.queueAddMany(tracks, playNext))
    fun requestRemove(itemId: String) = send(Protocol.queueRemove(itemId))
    fun requestMove(itemId: String, toIndex: Int) = send(Protocol.queueMove(itemId, toIndex))

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

    data class PlayerInfo(val playing: Boolean, val buffering: Boolean, val positionMs: Long, val durationMs: Long)

    /** Snapshot of the local player for the UI; call on the main thread. */
    fun playerInfo() = PlayerInfo(
        playing = exo.isPlaying,
        buffering = exo.playbackState == Player.STATE_BUFFERING,
        positionMs = exo.currentPosition.coerceAtLeast(0),
        durationMs = exo.duration.coerceAtLeast(0),
    )

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
        stopFollowing() // keep the saved room so the next start rejoins it
        scope.cancel()
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
        const val KEY_TRIM_MS = "trim_ms"
        const val KEY_START_BIAS_MS = "start_bias_ms"
        const val MAX_TRIM_MS = 1000L
    }
}
