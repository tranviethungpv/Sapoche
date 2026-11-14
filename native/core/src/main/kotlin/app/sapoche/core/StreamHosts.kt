package app.sapoche.core

import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Where else the stream at an address can be read from, and which of those servers could not be reached lately.
 *
 * A YouTube stream address names one server, `rr1---sn-aaa.googlevideo.com`, and lists in `mn=sn-aaa,sn-bbb` the servers
 * that hold the same file: the signature does not cover the name of the server, so the same path on the second one gives
 * the same bytes (read 2026-11-14: a range of three songs answered 206 from either). When the first cannot be connected
 * to, which on some networks happens to one cache server of the provider and not to another, the second can be.
 *
 * The number in `rr1` is not the same for every server: the provider's cache servers have `rr1` to `rr12`, the others
 * (read 2026-11-14) only `rr1` to `rr5`, and the name of one that does not exist is no host at all. So the first server
 * keeps the name the address gives it and the others are read as `rr1`, which every server has.
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
        val own = parts.groupValues[3]
        val listed = url.queryParameter("mn")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
        if (own !in listed) return listOf(url)
        val servers = listOf(own) + listed.filter { it != own }.distinct()
        val addresses = servers.map { server ->
            val number = if (server == own) parts.groupValues[2] else "1"
            url.newBuilder().host(parts.groupValues[1] + number + "---" + server + domain).build()
        }
        val (fine, lately) = addresses.partition { !isUnreachable(it.host) }
        return fine + lately
    }

    /**
     * [url]'s server could not be connected to: it is not tried first for a while. True when it was not already known to
     * be down, which is when it is worth telling.
     */
    fun markUnreachable(url: HttpUrl): Boolean {
        if (isUnreachable(url.host)) return false
        unreachable[url.host] = now() + rememberMs
        return true
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

        /** `rr1---sn-aaa`: the `rr`, its number, and the name of the server that the `mn` list repeats. */
        private val SERVER = Regex("""^(r+)(\d+)---(sn-[a-z0-9-]+)$""")

        val shared = StreamHosts()

        /**
         * The server could not be connected to (refused, no route, no answer to the first packet, no address for its
         * name), as opposed to one that answered badly or stopped halfway, which another server will not mend. With no
         * network at all every server fails this way, and then the failure is the one of the first, as it always was.
         * Looks through the causes, as the connection's own failure comes wrapped.
         */
        fun isConnectFailure(error: Throwable): Boolean = generateSequence(error) { it.cause }.take(8).any {
            it is ConnectException || it is NoRouteToHostException || it is UnknownHostException ||
                (it is SocketTimeoutException && it.message?.contains("connect", ignoreCase = true) == true)
        }
    }
}

/**
 * Reads a stream address from another of its servers when one cannot be connected to. Every server but the last to try
 * is given [SHORT_CONNECT_MS] to answer, so a dead one costs seconds, not the usual fifteen; the last gets the usual
 * time, so a slow network is no worse off than before.
 *
 * The server the address names is the one that is always tried, so the fallback is never worse than having none:
 * - A substitute (another server of the list, under a name this made up) is a guess. Whatever goes wrong with it, which
 *   is a failure to connect, no address for its name, a refusal (403, 404, 5xx), a broken handshake or a reset, is
 *   only a reason to try the next one, never the answer, and it is not tried first again for a while.
 * - The server the address names answers as it always did: a refusal or a broken read is the answer; only a failure to
 *   connect to it sends the read to the others.
 * - When no server serves it, the answer is the failure of the server the address names, so what the callers see
 *   (`StreamCache.isOffline`, `PatientLoadErrorPolicy`) is what it was before.
 */
class StreamHostFallback(
    private val hosts: StreamHosts = StreamHosts.shared,
    private val shortConnectMs: Long = SHORT_CONNECT_MS,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val addresses = hosts.candidates(request.url)
        if (addresses.size < 2) return chain.proceed(request)
        var named: IOException? = null // what the server the address names failed with
        var other: IOException? = null // what a substitute failed with
        for ((i, address) in addresses.withIndex()) {
            val substitute = address.host != request.url.host
            val last = i == addresses.lastIndex
            val step = if (last) chain else chain.withConnectTimeout(shortConnectMs.toInt(), TimeUnit.MILLISECONDS)
            val failure = try {
                val response = step.proceed(request.newBuilder().url(address).build())
                if (response.isSuccessful || !substitute) return response
                response.close()
                Refused(response.code)
            } catch (e: IOException) {
                if (chain.call().isCanceled() || (!substitute && !StreamHosts.isConnectFailure(e))) throw e
                e
            }
            if (substitute) other = other ?: failure else named = failure
            val fresh = hosts.markUnreachable(address)
            val cause = if (failure is Refused) "HTTP ${failure.code}" else generateSequence<Throwable>(failure) { it.cause }.last().javaClass.simpleName
            val what = if (StreamHosts.isConnectFailure(failure)) "could not be connected to" else "did not give the stream"
            if (fresh) hosts.onEvent("${address.host} $what ($cause), " + if (last) "no other server" else "trying ${addresses[i + 1].host}")
        }
        throw named ?: other!!
    }

    /** A substitute answered, but not with the stream. */
    private class Refused(val code: Int) : IOException("answered $code")

    companion object {
        const val SHORT_CONNECT_MS = 5_000L
    }
}
