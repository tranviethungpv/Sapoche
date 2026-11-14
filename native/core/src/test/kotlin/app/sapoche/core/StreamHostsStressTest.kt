package app.sapoche.core

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.IOException
import java.net.ConnectException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLHandshakeException
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Every way the servers of one address can answer, in every combination, over and over, against what the fallback must
 * never do: be worse than reading from the server the address names, which is what the app did before it existed.
 * (2026-11-14: a made-up name that had no address, and a server remembered as down, made every retry of a song fail
 * for five minutes while the server the address names was fine.)
 */
class StreamHostsStressTest {

    private enum class Outcome(val connect: Boolean) {
        OK(false),
        REFUSED(true),
        CONNECT_TIMEOUT(true),
        NO_ADDRESS(true),
        NO_ROUTE(true),
        HTTP_403(false),
        HTTP_404(false),
        HTTP_416(false),
        HTTP_500(false),
        RESET(false),
        TLS_BROKEN(false),
        READ_TIMEOUT(false),
    }

    /** What each server of one call does, and what it was asked. */
    private class Plan(val outcomes: Map<String, Outcome>) {
        val asked = Collections.synchronizedList(mutableListOf<String>())
        val failures = Collections.synchronizedMap(mutableMapOf<String, IOException>())
    }

    private val named = "rr12---sn-aaa.googlevideo.com"
    private val others = listOf("rr1---sn-bbb.googlevideo.com", "rr1---sn-ccc.googlevideo.com")
    private val all = listOf(named) + others
    private val address: HttpUrl = "https://$named/videoplayback?expire=1&mn=sn-aaa,sn-bbb,sn-ccc&sig=x".toHttpUrl()

    /** The servers: they answer as the plan of the call says, with no network. */
    private val servers = Interceptor { chain ->
        val request = chain.request()
        val plan = request.tag(Plan::class.java)!!
        val host = request.url.host
        plan.asked += host
        fun fail(e: IOException): Nothing {
            plan.failures[host] = e
            throw e
        }
        fun answer(code: Int) = Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(code).message("m")
            .header("X-Host", host).body("".toResponseBody()).build()
        when (plan.outcomes.getValue(host)) {
            Outcome.OK -> answer(206)
            Outcome.REFUSED -> fail(ConnectException("Failed to connect to $host/1.2.3.4:443"))
            Outcome.CONNECT_TIMEOUT -> fail(SocketTimeoutException("failed to connect to $host/1.2.3.4 (port 443) after 15000ms"))
            Outcome.NO_ADDRESS -> fail(UnknownHostException("Unable to resolve host \"$host\": No address associated with hostname"))
            Outcome.NO_ROUTE -> fail(java.net.NoRouteToHostException("no route"))
            Outcome.HTTP_403 -> answer(403)
            Outcome.HTTP_404 -> answer(404)
            Outcome.HTTP_416 -> answer(416)
            Outcome.HTTP_500 -> answer(500)
            Outcome.RESET -> fail(SocketException("Connection reset"))
            Outcome.TLS_BROKEN -> fail(SSLHandshakeException("Handshake failed"))
            Outcome.READ_TIMEOUT -> fail(SocketTimeoutException("timeout"))
        }
    }

    private fun client(hosts: StreamHosts) = OkHttpClient.Builder()
        .addInterceptor(StreamHostFallback(hosts, 5_000))
        .addInterceptor(servers)
        .build()

    /** Makes one call and checks the answer against what the plan makes of it. */
    private fun call(client: OkHttpClient, plan: Plan) {
        val request = Request.Builder().url(address).tag(Plan::class.java, plan).build()
        val own = plan.outcomes.getValue(named)
        val result = runCatching { client.newCall(request).execute() }
        val response = result.getOrNull()
        val what = "plan=${plan.outcomes.entries.joinToString { "${it.key.substringBefore("---")}.${it.key.substringAfter("---").substringBefore(".")}=${it.value}" }} asked=${plan.asked}"

        // Nothing is asked twice, nothing is asked that the address does not list
        assertEquals(plan.asked.toSet().size, plan.asked.size, "a server asked twice: $what")
        assertTrue(plan.asked.all { it in all }, what)

        val someoneServes = plan.outcomes.any { it.value == Outcome.OK }
        when {
            // The server the address names is fine: the read succeeds, whatever the others are
            own == Outcome.OK -> assertTrue(response?.isSuccessful == true, "the named server is fine and the read failed: $what")
            // It cannot be connected to: any server that serves is enough, and when none does the failure is its own
            own.connect -> if (someoneServes) {
                assertTrue(response?.isSuccessful == true, "a server serves and the read failed: $what")
            } else {
                assertSame(plan.failures.getValue(named), result.exceptionOrNull(), "not the failure of the named server: $what")
            }
            // It answers badly: the read is a success some other server gave first, or the answer of the named server, never of another
            else -> when {
                response != null && response.isSuccessful -> Unit
                response != null -> assertEquals(named, response.header("X-Host"), "the refusal of a substitute was the answer: $what")
                else -> assertSame(plan.failures.getValue(named), result.exceptionOrNull(), "the failure of a substitute was the answer: $what")
            }
        }
        response?.close()
    }

    private fun randomPlan(random: Random, weights: List<Outcome> = Outcome.entries) =
        Plan(all.associateWith { weights[random.nextInt(weights.size)] })

    @Test
    fun `every combination of how three servers answer, in order, over a long run with the clock jumping`() {
        // 12^3 = 1728 combinations, each tried in several orders of events by the memory of the servers
        for (seed in 1..6) {
            val random = Random(seed)
            var clock = 1_000L
            val hosts = StreamHosts(now = { clock })
            val client = client(hosts)
            repeat(12_000) {
                call(client, randomPlan(random))
                clock += when (random.nextInt(4)) {
                    0 -> 0L
                    1 -> 1_000L
                    2 -> StreamHosts.REMEMBER_MS - 1
                    else -> StreamHosts.REMEMBER_MS * 2
                }
            }
        }
    }

    @Test
    fun `all 1728 combinations once each, against a memory that has seen every kind of failure`() {
        val random = Random(7)
        var clock = 1_000L
        val hosts = StreamHosts(now = { clock })
        val client = client(hosts)
        // Teach the memory first: every server down, then up again, in random order
        repeat(200) { call(client, randomPlan(random)); clock += 10_000 }
        val outcomes = Outcome.entries
        for (a in outcomes) for (b in outcomes) for (c in outcomes) {
            call(client, Plan(mapOf(named to a, others[0] to b, others[1] to c)))
            clock += 1_000
        }
    }

    @Test
    fun `the day of the log, a server that is down and others whose made-up names are no hosts, again and again`() {
        // The made-up name has no address (as rr12---sn-oguelnsr had none), the named server comes and goes
        var clock = 1_000L
        val hosts = StreamHosts(now = { clock })
        val client = client(hosts)
        val random = Random(11)
        repeat(3_000) {
            val named = if (random.nextInt(3) == 0) Outcome.OK else Outcome.CONNECT_TIMEOUT
            call(client, Plan(mapOf(this.named to named, others[0] to Outcome.NO_ADDRESS, others[1] to Outcome.NO_ADDRESS)))
            clock += random.nextLong(0, 90_000)
        }
    }

    @Test
    fun `a substitute that is refused forever does not keep the named server from being read`() {
        var clock = 1_000L
        val hosts = StreamHosts(now = { clock })
        val client = client(hosts)
        // First the named server is down, so the others are put first; then it is back, and the others refuse
        call(client, Plan(mapOf(named to Outcome.CONNECT_TIMEOUT, others[0] to Outcome.HTTP_403, others[1] to Outcome.TLS_BROKEN)))
        repeat(50) {
            for (refusal in listOf(Outcome.HTTP_403, Outcome.HTTP_404, Outcome.HTTP_500, Outcome.RESET, Outcome.TLS_BROKEN, Outcome.NO_ADDRESS)) {
                call(client, Plan(mapOf(named to Outcome.OK, others[0] to refusal, others[1] to refusal)))
            }
            clock += 1_000
        }
    }

    @Test
    fun `many threads at once keep to the same rules`() {
        val hosts = StreamHosts()
        val client = client(hosts)
        val pool = Executors.newFixedThreadPool(16)
        val done = CountDownLatch(16)
        val broken = AtomicInteger()
        val worry = Collections.synchronizedList(mutableListOf<Throwable>())
        repeat(16) { thread ->
            pool.execute {
                try {
                    val random = Random(100 + thread)
                    repeat(1_500) { call(client, randomPlan(random)) }
                } catch (t: Throwable) {
                    broken.incrementAndGet()
                    worry += t
                } finally {
                    done.countDown()
                }
            }
        }
        assertTrue(done.await(120, TimeUnit.SECONDS), "threads did not finish")
        pool.shutdownNow()
        if (broken.get() > 0) fail("${broken.get()} threads broke the rules: ${worry.first()}")
    }

    @Test
    fun `a call that is cancelled is never answered with the failure of a server`() {
        val hosts = StreamHosts()
        val cancelling = OkHttpClient.Builder()
            .addInterceptor(StreamHostFallback(hosts, 5_000))
            .addInterceptor(Interceptor { chain ->
                chain.call().cancel()
                throw java.io.InterruptedIOException("canceled")
            })
            .build()
        val request = Request.Builder().url(address).tag(Plan::class.java, Plan(emptyMap())).build()
        val failure = runCatching { cancelling.newCall(request).execute() }.exceptionOrNull()
        assertTrue(failure is IOException, failure.toString())
        // Cancelled on the first: the others are not tried, nothing is remembered as down
        assertEquals(address.host, hosts.candidates(address).first().host)
    }

    // ------------------------------------------------------------------ skipping through songs

    /** Servers that take [takeMs] to answer, and give up at once, as a real call does, when it is cancelled meanwhile. */
    private fun slowServers(takeMs: Long, outcomes: Map<String, Outcome>) = Interceptor { chain ->
        val host = chain.request().url.host
        val until = System.nanoTime() + takeMs * 1_000_000
        while (System.nanoTime() < until) {
            if (chain.call().isCanceled()) throw IOException("Canceled")
            Thread.sleep(1)
        }
        if (chain.call().isCanceled()) throw IOException("Canceled")
        when (outcomes.getValue(host)) {
            Outcome.OK -> Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(206).message("m").body("".toResponseBody()).build()
            Outcome.CONNECT_TIMEOUT -> throw SocketTimeoutException("failed to connect to $host after 15000ms")
            else -> throw ConnectException("refused")
        }
    }

    /** Presses "next" over and over: every call is cancelled at a random moment, some in the middle of the fallback. */
    private fun skipping(outcomes: Map<String, Outcome>, takeMs: Long, calls: Int, hosts: StreamHosts): Pair<Int, Int> {
        val client = OkHttpClient.Builder().addInterceptor(StreamHostFallback(hosts, 5_000)).addInterceptor(slowServers(takeMs, outcomes)).build()
        val scheduler = Executors.newScheduledThreadPool(4)
        val random = Random(77)
        var done = 0
        var stopped = 0
        try {
            repeat(calls) {
                val call = client.newCall(Request.Builder().url(address).build())
                val cancelAfter = random.nextLong(0, takeMs * 3)
                scheduler.schedule({ call.cancel() }, cancelAfter, TimeUnit.MILLISECONDS)
                try {
                    call.execute().close()
                    done++
                } catch (e: IOException) {
                    // Only a call that was cancelled may fail here; the servers of this plan all serve in the end
                    assertTrue(call.isCanceled(), "a call that was not cancelled failed with $e")
                    stopped++
                }
            }
        } finally {
            scheduler.shutdownNow()
        }
        return done to stopped
    }

    @Test
    fun `skipping through songs, cancelling at any moment, never makes a server that is fine look down`() {
        val hosts = StreamHosts()
        val (done, stopped) = skipping(all.associateWith { Outcome.OK }, takeMs = 15, calls = 600, hosts = hosts)
        assertTrue(done > 50 && stopped > 50, "done=$done stopped=$stopped: the cancels should fall both before and after the answer")
        // Nothing failed but cancelled calls, so no server is remembered as down: the named one is still tried first
        assertEquals(named, hosts.candidates(address).first().host)
        assertEquals(address.host, hosts.candidates(address).first().host)
    }

    @Test
    fun `skipping through songs while the named server is down, a call is read from another or stopped, never failed`() {
        val hosts = StreamHosts()
        val (done, stopped) = skipping(mapOf(named to Outcome.CONNECT_TIMEOUT, others[0] to Outcome.OK, others[1] to Outcome.OK), takeMs = 15, calls = 600, hosts = hosts)
        assertTrue(done > 50, "done=$done stopped=$stopped")
        // The named server went down for good reason, so it is last; the others, which only ever served or were cancelled, keep their order
        assertEquals(others + named, hosts.candidates(address).map { it.host })
    }

    @Test
    fun `skipping through songs while every server is down, a call is stopped or fails with the failure of the named one`() {
        val hosts = StreamHosts()
        val client = OkHttpClient.Builder().addInterceptor(StreamHostFallback(hosts, 5_000))
            .addInterceptor(slowServers(5, all.associateWith { Outcome.CONNECT_TIMEOUT })).build()
        val random = Random(78)
        val scheduler = Executors.newScheduledThreadPool(2)
        try {
            repeat(300) {
                val call = client.newCall(Request.Builder().url(address).build())
                scheduler.schedule({ call.cancel() }, random.nextLong(0, 25), TimeUnit.MILLISECONDS)
                val failure = runCatching { call.execute().close() }.exceptionOrNull()
                assertTrue(failure is IOException, failure.toString())
                if (!call.isCanceled()) assertTrue(failure is SocketTimeoutException && named in failure.message.orEmpty(), failure.toString())
            }
        } finally {
            scheduler.shutdownNow()
        }
    }

    // ------------------------------------------------------------------ the names

    private val serverNames = listOf("sn-aaa", "sn-bbb", "sn-ccc", "sn-ddd-eee", "sn-42u-i5oss", "sn-oguelnsr", "sn-i3b7knse", "sn-ajoguc-5f")

    @Test
    fun `whatever the address, the names made up are real names of servers and the named one is never left out`() {
        val random = Random(5)
        val hosts = StreamHosts(now = { 0L })
        repeat(20_000) {
            val letters = "r".repeat(random.nextInt(1, 3))
            val number = random.nextInt(1, 40)
            val own = serverNames[random.nextInt(serverNames.size)]
            val listed = List(random.nextInt(0, 5)) { serverNames[random.nextInt(serverNames.size)] }.let {
                if (random.nextBoolean()) listOf(own) + it else it + own
            }
            val domain = if (random.nextInt(8) == 0) "example.com" else "googlevideo.com"
            val mn = listed.joinToString(if (random.nextInt(6) == 0) " , " else ",")
            val url = "https://$letters$number---$own.$domain/videoplayback?a=1&mn=$mn&z=%2C&sig=x".toHttpUrl()
            if (random.nextInt(3) == 0) hosts.markUnreachable(url.newBuilder().host("${letters}1---${serverNames[random.nextInt(serverNames.size)]}.googlevideo.com").build())

            val candidates = hosts.candidates(url)
            // The path and the query are those of the address, the scheme too
            assertTrue(candidates.all { it.encodedPath == url.encodedPath && it.encodedQuery == url.encodedQuery && it.scheme == url.scheme }, url.toString())
            // The named server is always one of them, as it was given
            assertTrue(url.host in candidates.map { it.host }, "$url -> $candidates")
            // No server twice
            assertEquals(candidates.size, candidates.map { it.host }.toSet().size, "$url -> $candidates")
            // The others are named as a server with rr1 has, and are servers the address lists
            for (c in candidates.filter { it.host != url.host }) {
                assertTrue(Regex("""^r+1---(sn-[a-z0-9-]+)\.googlevideo\.com$""").matches(c.host), c.host)
                assertTrue(c.host.substringAfter("---").removeSuffix(".googlevideo.com") in listed.map { it.trim() }, "$url -> $c")
            }
            if (domain != "googlevideo.com") assertEquals(listOf(url), candidates)
        }
    }

    @Test
    fun `addresses that are not streams are left alone and never throw`() {
        val hosts = StreamHosts()
        for (text in listOf(
            "https://music.youtube.com/youtubei/v1/player?mn=sn-a,sn-b",
            "https://redirector.googlevideo.com/videoplayback?mn=sn-a,sn-b",
            "https://rr1.sn-aaa.googlevideo.com/videoplayback?mn=sn-aaa,sn-bbb",
            "https://rrx---sn-aaa.googlevideo.com/videoplayback?mn=sn-aaa,sn-bbb",
            "https://rr---sn-aaa.googlevideo.com/videoplayback?mn=sn-aaa,sn-bbb",
            "https://rr1---xx-aaa.googlevideo.com/videoplayback?mn=xx-aaa,sn-bbb",
            "https://rr1---sn-AAA.googlevideo.com/videoplayback?mn=sn-AAA,sn-bbb",
            "https://rr1---sn-aaa.googlevideo.com/videoplayback",
            "https://rr1---sn-aaa.googlevideo.com/videoplayback?mn=",
            "https://rr1---sn-aaa.googlevideo.com/videoplayback?mn=,,",
            "http://localhost:8080/a?mn=sn-a,sn-b",
        )) {
            val url = text.toHttpUrl()
            assertEquals(1, hosts.candidates(url).size, text)
        }
    }
}
