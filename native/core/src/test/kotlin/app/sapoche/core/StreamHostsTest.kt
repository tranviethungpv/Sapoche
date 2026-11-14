package app.sapoche.core

import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.net.ConnectException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.ExecutionException
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StreamHostsTest {

    private var clock = 1_000L
    private val hosts = StreamHosts(now = { clock })

    private fun address(server: String = "sn-aaa", mn: String? = "sn-aaa,sn-bbb", host: String = "rr1---$server.googlevideo.com"): HttpUrl =
        "https://$host/videoplayback?expire=1&mn=${mn ?: ""}&sig=x".toHttpUrl()

    private fun hostsOf(url: HttpUrl) = hosts.candidates(url).map { it.host }

    @Test
    fun `the servers an address lists are tried in the order it lists them`() {
        assertEquals(listOf("rr1---sn-aaa.googlevideo.com", "rr1---sn-bbb.googlevideo.com"), hostsOf(address()))
    }

    @Test
    fun `only the name of the server changes, nothing else of the address`() {
        val other = hosts.candidates(address()).last()
        assertEquals(address().newBuilder().host("rr1---sn-bbb.googlevideo.com").build(), other)
    }

    @Test
    fun `an address that lists the server it names last is read from it first`() {
        assertEquals(listOf("rr2---sn-bbb.googlevideo.com", "rr2---sn-aaa.googlevideo.com"), hostsOf(address("sn-bbb", "sn-bbb,sn-aaa", "rr2---sn-bbb.googlevideo.com")))
    }

    @Test
    fun `an address with no other server is read from the one it names`() {
        assertEquals(1, hostsOf(address(mn = null)).size)
        assertEquals(1, hostsOf(address(mn = "sn-aaa")).size)
        // The list does not hold the server the address names: not an address this knows how to read
        assertEquals(1, hostsOf(address(mn = "sn-ccc,sn-ddd")).size)
    }

    @Test
    fun `what is not a stream server is left alone`() {
        assertEquals(1, hostsOf("https://redirector.googlevideo.com/videoplayback?mn=sn-aaa,sn-bbb".toHttpUrl()).size)
        assertEquals(1, hostsOf("https://rr1---sn-aaa.example.com/videoplayback?mn=sn-aaa,sn-bbb".toHttpUrl()).size)
        assertEquals(1, hostsOf("https://music.youtube.com/youtubei/v1/player?mn=sn-aaa,sn-bbb".toHttpUrl()).size)
    }

    @Test
    fun `a server that could not be connected to goes last for a while and then comes back`() {
        hosts.markUnreachable(address())
        assertEquals(listOf("rr1---sn-bbb.googlevideo.com", "rr1---sn-aaa.googlevideo.com"), hostsOf(address()))
        clock += StreamHosts.REMEMBER_MS - 1
        assertEquals("rr1---sn-bbb.googlevideo.com", hostsOf(address()).first())
        clock += 1
        assertEquals("rr1---sn-aaa.googlevideo.com", hostsOf(address()).first())
    }

    @Test
    fun `the servers are remembered by name, whatever the address`() {
        hosts.markUnreachable(address())
        val another = "https://rr1---sn-aaa.googlevideo.com/videoplayback?id=2&mn=sn-aaa,sn-bbb".toHttpUrl()
        assertEquals("rr1---sn-bbb.googlevideo.com", hostsOf(another).first())
    }

    @Test
    fun `a failure to connect is told from other failures`() {
        assertTrue(StreamHosts.isConnectFailure(ConnectException("Failed to connect to rr1---sn-aaa.googlevideo.com/1.2.3.4:443")))
        assertTrue(StreamHosts.isConnectFailure(NoRouteToHostException("no route")))
        assertTrue(StreamHosts.isConnectFailure(SocketTimeoutException("failed to connect to rr1---sn-aaa.googlevideo.com/1.2.3.4 (port 443) after 15000ms")))
        // As the log of a phone showed it: wrapped twice
        assertTrue(StreamHosts.isConnectFailure(IOException(ExecutionException(SocketTimeoutException("failed to connect to host after 15000ms")))))
        assertFalse(StreamHosts.isConnectFailure(SocketTimeoutException("timeout")))
        assertFalse(StreamHosts.isConnectFailure(SocketTimeoutException("Read timed out")))
        assertFalse(StreamHosts.isConnectFailure(IOException("unexpected end of stream")))
        // No name for the server says nothing of the server
        assertFalse(StreamHosts.isConnectFailure(UnknownHostException("rr1---sn-aaa.googlevideo.com")))
    }

    // ------------------------------------------------------------------ the interceptor, against real sockets

    private lateinit var server: MockWebServer
    private val events = mutableListOf<String>()

    /** The servers here are under another name than YouTube's. */
    private val local get() = StreamHosts(now = { clock }, domain = ".test").also { it.onEvent = { line -> events += line } }

    /** A client whose DNS puts every server name at the address [where] gives: 127.0.0.2 has nothing listening (connecting is refused), 127.0.0.1 is the server. */
    private fun client(hosts: StreamHosts, shortConnectMs: Long = StreamHostFallback.SHORT_CONNECT_MS, where: (String) -> String): OkHttpClient = OkHttpClient.Builder()
        .dns(Dns { name -> listOf(InetAddress.getByName(where(name))) })
        .addInterceptor(StreamHostFallback(hosts, shortConnectMs))
        .build()

    private fun stream(mn: String? = "sn-aaa,sn-bbb"): Request =
        Request.Builder().url("http://rr1---sn-aaa.test:${server.port}/videoplayback" + (mn?.let { "?mn=$it" } ?: "")).build()

    @BeforeTest
    fun start() {
        server = MockWebServer().also { it.start() }
    }

    @AfterTest
    fun stop() {
        server.close()
    }

    @Test
    fun `a server that refuses is read from another, and not tried first again`() {
        val hosts = local
        val client = client(hosts) { if ("sn-aaa" in it) "127.0.0.2" else "127.0.0.1" }
        server.enqueue(MockResponse.Builder().code(206).body("one").build())
        server.enqueue(MockResponse.Builder().code(206).body("two").build())

        client.newCall(stream()).execute().use { assertEquals("one", it.body.string()) }
        assertEquals("rr1---sn-bbb.test", hosts.candidates(stream().url).first().host)
        client.newCall(stream()).execute().use { assertEquals("two", it.body.string()) }

        assertEquals(2, server.requestCount)
        assertEquals(1, events.size)
        assertTrue("rr1---sn-aaa.test could not be connected to" in events.single() && "trying rr1---sn-bbb.test" in events.single(), events.single())
    }

    @Test
    fun `a server that does not answer at all is given up on after the short wait and another is read from`() {
        // Nothing accepts at 127.0.0.2, and its queue is full, so a connection attempt there gets no answer
        val silent = ServerSocket(server.port, 1, InetAddress.getByName("127.0.0.2"))
        val held = mutableListOf<Socket>()
        try {
            repeat(6) { runCatching { held += Socket().also { it.connect(InetSocketAddress("127.0.0.2", server.port), 200) } } }
            val hosts = local
            val client = client(hosts, shortConnectMs = 300) { if ("sn-aaa" in it) "127.0.0.2" else "127.0.0.1" }
            server.enqueue(MockResponse.Builder().code(206).body("served").build())

            val start = System.nanoTime()
            client.newCall(stream()).execute().use { assertEquals("served", it.body.string()) }
            val tookMs = (System.nanoTime() - start) / 1_000_000

            assertTrue(tookMs < 3_000, "took $tookMs ms")
            assertEquals("rr1---sn-bbb.test", hosts.candidates(stream().url).first().host)
            assertTrue("SocketTimeoutException" in events.single(), events.single())
        } finally {
            held.forEach { runCatching { it.close() } }
            silent.close()
        }
    }

    @Test
    fun `an answer that is not a success is the answer, not a reason to go to another server`() {
        val client = client(local) { "127.0.0.1" }
        server.enqueue(MockResponse.Builder().code(403).build())
        client.newCall(stream()).execute().use { assertEquals(403, it.code) }
        assertEquals(1, server.requestCount)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `when no server can be connected to the failure is the one of the first`() {
        val client = client(local) { "127.0.0.2" }
        val failure = assertFailsWith<IOException> { client.newCall(stream()).execute() }
        assertTrue(StreamHosts.isConnectFailure(failure))
        assertEquals(2, events.size)
        assertTrue("no other server" in events.last())
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `an address with no other server fails as it always did`() {
        val client = client(local) { "127.0.0.2" }
        assertFailsWith<IOException> { client.newCall(stream(mn = null)).execute() }
        assertTrue(events.isEmpty())
    }
}
