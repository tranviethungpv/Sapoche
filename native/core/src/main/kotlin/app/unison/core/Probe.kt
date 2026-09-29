package app.unison.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/** Result of checking whether a stream URL is actually downloadable. */
data class ProbeResult(
    val headStatus: Int,
    val midStatus: Int,
    val tailStatus: Int,
    val totalBytes: Long,
    val firstByteMs: Long,
) {
    /** Start, middle and end of the file all returned 200/206. */
    val ok get() = listOf(headStatus, midStatus, tailStatus).all { it == 200 || it == 206 }
}

/**
 * Some YouTube clients only serve the first ~60 seconds and then return 403
 * when a PO token is missing. So we probe the middle and end of the file too,
 * not just the first bytes.
 */
class Probe(private val client: OkHttpClient = OkHttpDownloader.defaultClient()) {

    suspend fun check(source: AudioSource, userAgent: String = OkHttpDownloader.USER_AGENT): ProbeResult =
        withContext(Dispatchers.IO) {
            val t0 = System.nanoTime()
            val (headStatus, total) = range(source.url, 0, 65_535, userAgent)
            val firstByteMs = (System.nanoTime() - t0) / 1_000_000
            val size = if (total > 0) total else source.contentLength
            val mid = if (size > 0) range(source.url, size / 2, size / 2 + 65_535, userAgent).first else -1
            val tail = if (size > 0) range(source.url, size - 65_536, size - 1, userAgent).first else -1
            ProbeResult(headStatus, mid, tail, size, firstByteMs)
        }

    /** Returns (HTTP status, total file size if the server reports it). */
    private fun range(url: String, from: Long, to: Long, userAgent: String): Pair<Int, Long> {
        val request = Request.Builder()
            .url(url)
            .header("Range", "bytes=$from-$to")
            .header("User-Agent", userAgent)
            .build()
        return client.newCall(request).execute().use { response ->
            // Read the whole chunk so mid-transfer failures surface here
            response.body.source().readByteArray()
            val total = response.header("Content-Range")?.substringAfter('/')?.toLongOrNull() ?: -1
            response.code to total
        }
    }
}
