package app.unison.sync

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** [REFUSED]: the server turned this device away for good (room full, no such room, removed by the owner). */
enum class Connection { CONNECTING, CONNECTED, RECONNECTING, CLOSED, UNAUTHORIZED, REFUSED }

/**
 * WebSocket connection to one room. Joins on every (re)connect, keeps the clock offset fresh with
 * pings, and reconnects with exponential backoff when the connection drops.
 */
class RoomClient(
    baseUrl: String,
    roomCode: String,
    private val clientId: String,
    name: String,
    private val scope: CoroutineScope,
    private val clock: ClockSync,
    /** Monotonic local clock in ms; must be the clock the GroupSession uses. */
    private val nowMs: () -> Long,
    private val log: (String) -> Unit = {},
    /** Sent with the WebSocket upgrade, e.g. the shared secret. */
    private val headers: Map<String, String> = emptyMap(),
    /**
     * What this device expects of the room, see [Protocol.join]. It is sent until the server has answered
     * once; after that a reconnect must not open a new room if the old one expired.
     */
    create: Boolean? = null,
    // No protocol-level pings here: the ping below already keeps the connection alive and proves it is
    // dead when unanswered, and a second timer would wake the radio twice as often
    private val http: OkHttpClient = OkHttpClient(),
    /** How often to ping once connected, and how long silence may last before the connection is dropped. Shortened by tests. */
    private val pingEveryMs: Long = REFRESH_MS,
    private val pongDeadlineMs: Long = PONG_DEADLINE_MS,
) {
    var onMessage: (ServerMessage) -> Unit = {}

    /** Called after each successful (re)connect, once the join message was sent. */
    var onConnected: () -> Unit = {}

    /** A member's picture arrived ([av] is its fingerprint), or with no [data] they took it away. */
    var onAvatar: (id: String, av: String?, data: String?) -> Unit = { _, _, _ -> }

    private val url = baseUrl.trimEnd('/').replaceFirst("http", "ws") + "/room/" + roomCode.uppercase()

    private val _connection = MutableStateFlow(Connection.CONNECTING)
    val connection: StateFlow<Connection> = _connection.asStateFlow()

    @Volatile
    private var socket: WebSocket? = null
    private var loop: Job? = null
    private var createOnJoin = create

    /** When the server last answered a ping, on the [nowMs] clock. */
    @Volatile
    private var lastPongMs = 0L

    /** This device's own picture, as base64; shared with the room once the server says it can keep pictures. */
    @Volatile
    private var avatar: String? = null

    /** What the server last said it can do, and whether the picture went out on this connection. */
    @Volatile
    private var serverProtocol = 0
    private var avatarSent = false

    /** The fingerprint of each member's picture as last asked for, so a picture is fetched once and not at every change. */
    private val known = HashMap<String, String>()

    /** A token here ends the current reconnect wait early. */
    private val wake = Channel<Unit>(Channel.CONFLATED)

    fun start() {
        if (loop != null) return
        loop = scope.launch { connectLoop() }
    }

    /** Shown to the others; sent again on every reconnect. */
    @Volatile
    var name: String = name
        private set

    fun send(text: String): Boolean = socket?.send(text) ?: false

    /** Sets, or with null takes away, the picture the others see of this device. Sent again on every reconnect. */
    fun setAvatar(data: String?) {
        avatar = data
        if (serverProtocol >= AVATAR_PROTOCOL) send(Protocol.avatarSet(data))
    }

    /** Changes the display name without dropping the connection: the server accepts a second join. */
    fun rename(newName: String) {
        name = newName
        send(Protocol.join(clientId, newName))
    }

    /**
     * The device's network changed or came back: do not wait out the backoff, and replace a connection
     * that may be dead without knowing it. Safe to call from any thread.
     */
    fun reconnectNow() {
        if (loop == null) return
        if (_connection.value == Connection.CONNECTED) socket?.cancel()
        wake.trySend(Unit)
    }

    /** Leaves on purpose: tells the room, so an owner hands it over, then closes. */
    fun leave() {
        send(Protocol.bye())
        close()
    }

    fun close() {
        loop?.cancel()
        loop = null
        socket?.close(1000, "leaving")
        socket = null
        _connection.value = Connection.CLOSED
    }

    private suspend fun connectLoop() {
        var attempt = 0
        while (scope.isActive) {
            _connection.value = if (attempt == 0) Connection.CONNECTING else Connection.RECONNECTING
            val closed = CompletableDeferred<Int>()
            var pinger: Job? = null

            val request = Request.Builder().url(url).apply { headers.forEach { (k, v) -> header(k, v) } }.build()
            val ws = http.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    attempt = 0
                    socket = webSocket
                    _connection.value = Connection.CONNECTED
                    log("connected to $url")
                    lastPongMs = nowMs()
                    avatarSent = false
                    webSocket.send(Protocol.join(clientId, name, createOnJoin))
                    pinger = scope.launch { pingLoop(webSocket) }
                    onConnected()
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    when (val msg = Protocol.parse(text)) {
                        null -> log("ignoring unparsable message")
                        is ServerMessage.Pong -> {
                            lastPongMs = nowMs()
                            clock.addSample(msg.c0, nowMs(), msg.s1)
                        }
                        is ServerMessage.Avatar -> {
                            if (msg.av != null) known[msg.id] = msg.av else known.remove(msg.id)
                            onAvatar(msg.id, msg.av, msg.data)
                        }
                        else -> {
                            if (msg is ServerMessage.State && createOnJoin == true) createOnJoin = false
                            if (msg is ServerMessage.State) {
                                serverProtocol = msg.protocol
                                shareAvatar(webSocket)
                                wantPictures(msg.members)
                            } else if (msg is ServerMessage.Members) {
                                wantPictures(msg.members)
                            }
                            onMessage(msg)
                        }
                    }
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(code, reason)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    log("closed: $code $reason")
                    closed.complete(code)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    log("connection failed: ${t.javaClass.simpleName}: ${t.message} (http ${response?.code})")
                    closed.complete(if (response?.code == HTTP_UNAUTHORIZED) CLOSE_UNAUTHORIZED else -1)
                }
            })

            val code = try {
                closed.await()
            } finally {
                pinger?.cancel()
                ws.cancel()
                if (socket === ws) socket = null
            }

            if (code == CLOSE_UNAUTHORIZED) {
                // A wrong or missing key stays wrong; retrying only hammers the server
                log("the server rejected our key, giving up")
                _connection.value = Connection.UNAUTHORIZED
                return
            }
            if (code == CLOSE_POLICY_VIOLATION || code == CLOSE_REMOVED || code == CLOSE_NOT_FOUND) {
                // The server refuses us (room full, removed by the owner, no such room); retrying would not help
                log("server refused the connection ($code), giving up")
                _connection.value = Connection.REFUSED
                return
            }
            val wait = backoffMs(attempt++)
            log("reconnecting in ${wait}ms")
            withTimeoutOrNull(wait) { wake.receive() }
        }
    }

    /** Hands the room this device's picture, once per connection, when the server can keep it. */
    private fun shareAvatar(ws: WebSocket) {
        if (avatarSent || serverProtocol < AVATAR_PROTOCOL) return
        avatarSent = true
        ws.send(Protocol.avatarSet(avatar))
    }

    /** Asks for the pictures of members whose picture changed since it was last fetched, and forgets those who are gone. */
    private fun wantPictures(members: List<Member>) {
        if (serverProtocol < AVATAR_PROTOCOL) return
        known.keys.retainAll(members.map { it.id }.toSet())
        for (member in members) {
            if (member.id == clientId) continue
            if (member.av == null) {
                // They had one and took it away
                if (known.remove(member.id) != null) onAvatar(member.id, null, null)
            } else if (known[member.id] != member.av) {
                known[member.id] = member.av
                socket?.send(Protocol.avatarGet(member.id))
            }
        }
    }

    /**
     * A quick burst right after connecting for a good first estimate, then a slow refresh: each ping keeps
     * the radio awake, and the server counts it as presence. A connection that stopped answering without
     * saying so is dropped here, since nothing else would notice.
     */
    private suspend fun pingLoop(ws: WebSocket) {
        repeat(BURST_PINGS) {
            ws.send(Protocol.ping(nowMs()))
            delay(BURST_GAP_MS)
        }
        while (true) {
            delay(pingEveryMs)
            if (nowMs() - lastPongMs > pongDeadlineMs) {
                log("no answer to pings for ${(nowMs() - lastPongMs) / 1000}s, dropping the connection")
                ws.cancel()
                return
            }
            ws.send(Protocol.ping(nowMs()))
        }
    }

    private fun backoffMs(attempt: Int): Long = minOf(15_000L, 1000L shl attempt.coerceAtMost(4))

    private companion object {
        /** The first protocol that keeps members' pictures. */
        const val AVATAR_PROTOCOL = 8
        const val CLOSE_POLICY_VIOLATION = 1008
        const val CLOSE_REMOVED = 4001
        const val CLOSE_NOT_FOUND = 4004
        const val CLOSE_UNAUTHORIZED = -401
        const val HTTP_UNAUTHORIZED = 401
        const val BURST_PINGS = 8
        const val BURST_GAP_MS = 250L
        const val REFRESH_MS = 30_000L

        /** A healthy connection answers every ping, one per [REFRESH_MS]; a whole missed round means it is dead. */
        const val PONG_DEADLINE_MS = 45_000L
    }
}
