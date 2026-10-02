package app.unison.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** RoomClient against a real WebSocket server on this machine, so the timing here is real time. */
class RoomClientTest {

    private lateinit var server: MockWebServer
    private lateinit var scope: CoroutineScope
    private val received = CopyOnWriteArrayList<String>()
    private val clients = CopyOnWriteArrayList<RoomClient>()

    @BeforeTest
    fun setUp() {
        server = MockWebServer().also { it.start() }
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }

    @AfterTest
    fun tearDown() {
        clients.forEach { it.close() }
        scope.cancel()
        server.close()
    }

    private val state = """{"t":"state","serverNow":0,"you":"me","state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":0},"members":[]}"""

    /** A room server that records what it hears, greets with a state, and then does what [react] says. */
    private fun room(react: (WebSocket, String) -> Unit = { _, _ -> }) = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            received += text
            if (text.contains("\"join\"")) webSocket.send(state)
            react(webSocket, text)
        }

        override fun onOpen(webSocket: WebSocket, response: Response) = Unit

        // Answer the client's close, or the connection stays half open and the server cannot shut down
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(code, reason)
        }
    }

    private fun accept(listener: WebSocketListener) {
        server.enqueue(MockResponse.Builder().webSocketUpgrade(listener).build())
    }

    private fun client(create: Boolean?, pingEveryMs: Long = 30_000, pongDeadlineMs: Long = 45_000) = RoomClient(
        baseUrl = server.url("/").toString().trimEnd('/'),
        roomCode = "ABC234",
        clientId = "me",
        name = "Me",
        scope = scope,
        clock = ClockSync(),
        nowMs = { System.nanoTime() / 1_000_000 },
        create = create,
        pingEveryMs = pingEveryMs,
        pongDeadlineMs = pongDeadlineMs,
    ).also { clients += it }

    private fun waitFor(timeoutMs: Long = 5000, condition: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            if (condition()) return true
            Thread.sleep(25)
        }
        return condition()
    }

    private fun joins() = received.filter { it.contains("\"join\"") }

    @Test
    fun `the first join says what the device expects and a reconnect no longer asks to create`() {
        accept(room { socket, text -> if (text.contains("\"join\"")) socket.close(1001, "going away") })
        accept(room())
        val client = client(create = true)
        client.start()

        assertTrue(waitFor { joins().size >= 2 }, "the client should join again after the connection dropped")
        assertTrue(joins()[0].contains("\"create\":true"), joins()[0])
        assertTrue(joins()[1].contains("\"create\":false"), "a room that was made must not be made again: ${joins()[1]}")
        client.close()
    }

    @Test
    fun `an older style join leaves the flag out`() {
        accept(room())
        val client = client(create = null)
        client.start()
        assertTrue(waitFor { joins().isNotEmpty() })
        assertTrue(!joins()[0].contains("create"), joins()[0])
        client.close()
    }

    @Test
    fun `a room that does not exist is a final answer`() {
        accept(room { socket, text -> if (text.contains("\"join\"")) socket.close(4004, "room not found") })
        accept(room()) // would be used by a retry
        val client = client(create = false)
        client.start()

        assertTrue(waitFor { client.connection.value == Connection.REFUSED })
        Thread.sleep(1500) // longer than the first retry delay
        assertEquals(1, server.requestCount, "no retry after a refusal")
    }

    @Test
    fun `being removed or a full room is refused for good too`() {
        for (code in listOf(4001, 1008)) {
            received.clear()
            val single = MockWebServer().also { it.start() }
            single.enqueue(
                MockResponse.Builder().webSocketUpgrade(object : WebSocketListener() {
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        if (text.contains("\"join\"")) webSocket.close(code, "no")
                    }
                }).build(),
            )
            val client = RoomClient(
                baseUrl = single.url("/").toString().trimEnd('/'),
                roomCode = "ABC234",
                clientId = "me",
                name = "Me",
                scope = scope,
                clock = ClockSync(),
                nowMs = { System.nanoTime() / 1_000_000 },
            )
            client.start()
            assertTrue(waitFor { client.connection.value == Connection.REFUSED }, "close code $code")
            single.close()
        }
    }

    @Test
    fun `leaving on purpose tells the room`() {
        accept(room())
        val client = client(create = false)
        client.start()
        assertTrue(waitFor { client.connection.value == Connection.CONNECTED && joins().isNotEmpty() })

        client.leave()
        assertTrue(waitFor { received.any { it.contains("\"bye\"") } }, "the room should hear bye before the socket closes")
        assertEquals(Connection.CLOSED, client.connection.value)
    }

    @Test
    fun `a connection that stops answering pings is dropped and rejoined`() {
        accept(room()) // never answers a ping
        accept(room())
        val client = client(create = false, pingEveryMs = 100, pongDeadlineMs = 300)
        client.start()

        assertTrue(waitFor(timeoutMs = 8000) { joins().size >= 2 }, "the silent connection should have been replaced")
        client.close()
    }

    @Test
    fun `a connection that answers its pings is left alone`() {
        val pong = Regex("\"c0\":(\\d+)")
        accept(
            room { socket, text ->
                if (text.contains("\"ping\"")) {
                    val c0 = pong.find(text)?.groupValues?.get(1) ?: return@room
                    socket.send("""{"t":"pong","c0":$c0,"s1":0}""")
                }
            },
        )
        accept(room()) // would be used if the client gave up on a healthy connection
        // The deadline must outlast the last pause of the first burst plus one round of the slow ping
        val client = client(create = false, pingEveryMs = 100, pongDeadlineMs = 800)
        client.start()

        assertTrue(waitFor { joins().isNotEmpty() })
        Thread.sleep(4000) // past the burst of first pings and several rounds of the slow ping
        assertEquals(1, server.requestCount, "a healthy connection must not be replaced")
        assertEquals(Connection.CONNECTED, client.connection.value)
        client.close()
    }

    private fun stateWith(protocol: Int, members: String) =
        """{"t":"state","serverNow":0,"you":"me","protocol":$protocol,"state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":0},"members":$members}"""

    @Test
    fun `an older server is sent no pictures, which it would answer with an error`() {
        accept(room()) // its state does not say it keeps pictures
        val c = client(create = false)
        c.setAvatar("TUlORQ==")
        c.start()
        assertTrue(waitFor { joins().isNotEmpty() })
        Thread.sleep(300)
        assertEquals(emptyList(), received.filter { it.contains("avatar") })
    }

    @Test
    fun `pictures are shared and fetched once the server speaks protocol 8`() {
        val members = """[{"id":"me","name":"Me","ready":false},{"id":"you","name":"You","ready":false,"av":"abcd1234"}]"""
        val heard = CopyOnWriteArrayList<Triple<String, String?, String?>>()
        val greeting = object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                received += text
                if (text.contains("\"join\"")) webSocket.send(stateWith(8, members))
                if (text.contains("\"avatar.get\"")) webSocket.send("""{"t":"avatar","id":"you","av":"abcd1234","data":"UElDVA=="}""")
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, reason)
            }
        }
        accept(greeting)
        val c = client(create = false)
        c.onAvatar = { id, av, data -> heard += Triple(id, av, data) }
        c.setAvatar("TUlORQ==")
        c.start()
        assertTrue(waitFor { heard.isNotEmpty() })
        assertEquals(Triple("you", "abcd1234", "UElDVA=="), heard.single())
        assertTrue(received.any { it.contains("\"avatar.set\"") && it.contains("TUlORQ==") })
        assertEquals(1, received.count { it.contains("\"avatar.get\"") && it.contains("\"you\"") })
        assertTrue(received.none { it.contains("\"avatar.get\"") && it.contains("\"me\"") }, "its own picture is not asked for")
    }
}
