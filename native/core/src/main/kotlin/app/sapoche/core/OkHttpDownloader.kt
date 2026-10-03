package app.sapoche.core

import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.TimeUnit

/** HTTP bridge for NewPipeExtractor, backed by OkHttp. */
class OkHttpDownloader(
    private val client: OkHttpClient = defaultClient(),
) : Downloader() {

    override fun execute(request: Request): Response {
        val body = request.dataToSend()?.toRequestBody()
        val builder = okhttp3.Request.Builder()
            .method(request.httpMethod(), body)
            .url(request.url())
            .addHeader("User-Agent", USER_AGENT)

        request.headers().forEach { (name, values) ->
            builder.removeHeader(name)
            values.forEach { builder.addHeader(name, it) }
        }

        client.newCall(builder.build()).execute().use { response ->
            if (response.code == 429) {
                throw ReCaptchaException("reCaptcha challenge requested", request.url())
            }
            return Response(
                response.code,
                response.message,
                response.headers.toMultimap(),
                response.body.string(),
                response.request.url.toString(),
            )
        }
    }

    companion object {
        const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; rv:128.0) Gecko/20100101 Firefox/128.0"

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .readTimeout(30, TimeUnit.SECONDS)
            .connectTimeout(15, TimeUnit.SECONDS)
            .dns(OneFamilyDns())
            .build()
    }
}

/**
 * The addresses of a host, only its IPv4 ones when it has any. A YouTube stream address is signed for the address of
 * the device that asked for it, so asking over IPv4 and fetching over IPv6, or the other way round, is refused with 403.
 * On a network with both, which one a connection takes is otherwise up to chance (OkHttp races the two).
 */
class OneFamilyDns(private val system: Dns = Dns.SYSTEM) : Dns {
    override fun lookup(hostname: String): List<InetAddress> {
        val all = system.lookup(hostname)
        return all.filterIsInstance<Inet4Address>().ifEmpty { all }
    }
}
