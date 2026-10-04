package app.sapoche.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
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
 * not just the first bytes. A broken part shows in the status of the answer, so
 * each part is small: on a slow network the probe comes before the first sound.
 */
class Probe(private val client: OkHttpClient = OkHttpDownloader.defaultClient()) {

    suspend fun check(source: AudioSource, userAgent: String = OkHttpDownloader.USER_AGENT): ProbeResult =
        check(source.url, source.contentLength, userAgent)

    suspend fun check(url: String, contentLength: Long, userAgent: String = OkHttpDownloader.USER_AGENT): ProbeResult =
        withContext(Dispatchers.IO) {
            val t0 = System.nanoTime()
            val head = async { range(url, 0, PART_BYTES - 1, userAgent) to (System.nanoTime() - t0) / 1_000_000 }
            // The size is nearly always known from the resolve, and then the three parts are asked for at once
            val size = if (contentLength > 0) contentLength else head.await().first.second
            val mid = async { if (size > 0) range(url, size / 2, size / 2 + PART_BYTES - 1, userAgent).first else -1 }
            val tail = async { if (size > 0) range(url, size - PART_BYTES, size - 1, userAgent).first else -1 }
            val (headAnswer, firstByteMs) = head.await()
            ProbeResult(headAnswer.first, mid.await(), tail.await(), size, firstByteMs)
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

    private companion object {
        const val PART_BYTES = 8_192L
    }
}
