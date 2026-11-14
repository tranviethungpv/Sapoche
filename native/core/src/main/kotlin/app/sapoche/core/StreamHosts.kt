package app.sapoche.core

import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Where else the stream at an address can be read from, and which of those servers could not be reached lately.
 *
 * A YouTube stream address names one server, `rr1---sn-aaa.googlevideo.com`, and lists in `mn=sn-aaa,sn-bbb` the servers
 * that hold the same file: the signature does not cover the name of the server, so the same path on the second one gives
 * the same bytes (read 2026-11-14: a range of three songs answered 206 from either). When the first cannot be connected
 * to, which on some networks happens to one cache server of the provider and not to another, the second can be.
 */
class StreamHosts(
    private val now: () -> Long = System::currentTimeMillis,
    private val rememberMs: Long = REMEMBER_MS,
    /** Only servers under this name are looked at; anything else is not a stream server. */
    private val domain: String = ".googlevideo.com",
) {
    /** Told when a server could not be connected to, and where the read goes on. Set once by the app, to its log. */
    @Volatile
    var onEvent: (String) -> Unit = {}

    /** Server name to the time (ms) until which it is not tried first. */
    private val unreachable = ConcurrentHashMap<String, Long>()

    /**
     * The addresses to read [url] from, the one to try first first: the servers that were fine, in the order the address
     * lists them, then the ones that could not be reached lately. One address when it names no other server.
     */
    fun candidates(url: HttpUrl): List<HttpUrl> {
        val host = url.host
        if (!host.endsWith(domain)) return listOf(url)
        val label = host.removeSuffix(domain)
        val parts = SERVER.matchEntire(label) ?: return listOf(url)
        val own = parts.groupValues[2]
        val listed = url.queryParameter("mn")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
        if (own !in listed) return listOf(url)
        val servers = listOf(own) + listed.filter { it != own }.distinct()
        val addresses = servers.map { server -> url.newBuilder().host(parts.groupValues[1] + server + domain).build() }
        val (fine, lately) = addresses.partition { !isUnreachable(it.host) }
        return fine + lately
    }

    /** [url]'s server could not be connected to: it is not tried first for a while. */
    fun markUnreachable(url: HttpUrl) {
        unreachable[url.host] = now() + rememberMs
    }

    private fun isUnreachable(host: String): Boolean {
        val until = unreachable[host] ?: return false
        if (now() < until) return true
        unreachable.remove(host, until)
        return false
    }

    companion object {
        /** Long enough for the songs of one sitting to skip a server that is down; short enough to try it again. */
        const val REMEMBER_MS = 5 * 60_000L

        /** `rr1---sn-aaa`: the prefix, and the name of the server that the `mn` list repeats. */
        private val SERVER = Regex("""^(r+\d+---)(sn-[a-z0-9-]+)$""")

        val shared = StreamHosts()

        /**
         * The server could not be connected to (refused, no route, no answer to the first packet), as opposed to one that
         * answered badly or stopped halfway, which another server will not mend. Looks through the causes, as the
         * connection's own failure comes wrapped.
         */
        fun isConnectFailure(error: Throwable): Boolean = generateSequence(error) { it.cause }.take(8).any {
            it is ConnectException || it is NoRouteToHostException ||
                (it is SocketTimeoutException && it.message?.contains("connect", ignoreCase = true) == true)
        }
    }
}

/**
 * Reads a stream address from another of its servers when one cannot be connected to. Every server but the last to try
 * is given [SHORT_CONNECT_MS] to answer, so a dead one costs seconds, not the usual fifteen; the last gets the usual
 * time, so a slow network is no worse off than before. Only the failure to connect is answered this way.
 */
class StreamHostFallback(
    private val hosts: StreamHosts = StreamHosts.shared,
    private val shortConnectMs: Long = SHORT_CONNECT_MS,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val addresses = hosts.candidates(request.url)
        if (addresses.size < 2) return chain.proceed(request)
        var first: IOException? = null
        for ((i, address) in addresses.withIndex()) {
            val last = i == addresses.lastIndex
            val step = if (last) chain else chain.withConnectTimeout(shortConnectMs.toInt(), TimeUnit.MILLISECONDS)
            try {
                return step.proceed(request.newBuilder().url(address).build())
            } catch (e: IOException) {
                if (!StreamHosts.isConnectFailure(e) || chain.call().isCanceled()) throw e
                hosts.markUnreachable(address)
                first = first ?: e
                val cause = generateSequence<Throwable>(e) { it.cause }.last().javaClass.simpleName
                hosts.onEvent("${address.host} could not be connected to ($cause), " + if (last) "no other server" else "trying ${addresses[i + 1].host}")
            }
        }
        throw first!!
    }

    companion object {
        const val SHORT_CONNECT_MS = 5_000L
    }
}
