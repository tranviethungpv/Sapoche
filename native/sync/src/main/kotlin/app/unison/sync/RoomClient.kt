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
import java.util.concurrent.TimeUnit

enum class Connection { CONNECTING, CONNECTED, RECONNECTING, CLOSED, UNAUTHORIZED }

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
    private val http: OkHttpClient = OkHttpClient.Builder()
        // Protocol-level pings keep NAT mappings alive and detect dead connections
        .pingInterval(20, TimeUnit.SECONDS)
        .build(),
) {
    var onMessage: (ServerMessage) -> Unit = {}

    /** Called after each successful (re)connect, once the join message was sent. */
    var onConnected: () -> Unit = {}

    private val url = baseUrl.trimEnd('/').replaceFirst("http", "ws") + "/room/" + roomCode.uppercase()

    private val _connection = MutableStateFlow(Connection.CONNECTING)
    val connection: StateFlow<Connection> = _connection.asStateFlow()

    @Volatile
    private var socket: WebSocket? = null
    private var loop: Job? = null

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
                    webSocket.send(Protocol.join(clientId, name))
                    pinger = scope.launch { pingLoop(webSocket) }
                    onConnected()
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    when (val msg = Protocol.parse(text)) {
                        null -> log("ignoring unparsable message")
                        is ServerMessage.Pong -> clock.addSample(msg.c0, nowMs(), msg.s1)
                        else -> onMessage(msg)
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
            if (code == CLOSE_POLICY_VIOLATION) {
                // The server refuses us (room full); retrying would not help
                log("server refused the connection, giving up")
                _connection.value = Connection.CLOSED
                return
            }
            val wait = backoffMs(attempt++)
            log("reconnecting in ${wait}ms")
            withTimeoutOrNull(wait) { wake.receive() }
        }
    }

    /** A quick burst right after connecting for a good first estimate, then a slow refresh: each ping keeps the radio awake, and the server counts it as presence. */
    private suspend fun pingLoop(ws: WebSocket) {
        repeat(BURST_PINGS) {
            ws.send(Protocol.ping(nowMs()))
            delay(BURST_GAP_MS)
        }
        while (true) {
            delay(REFRESH_MS)
            ws.send(Protocol.ping(nowMs()))
        }
    }

    private fun backoffMs(attempt: Int): Long = minOf(15_000L, 1000L shl attempt.coerceAtMost(4))

    private companion object {
        const val CLOSE_POLICY_VIOLATION = 1008
        const val CLOSE_UNAUTHORIZED = -401
        const val HTTP_UNAUTHORIZED = 401
        const val BURST_PINGS = 8
        const val BURST_GAP_MS = 250L
        const val REFRESH_MS = 30_000L
    }
}
