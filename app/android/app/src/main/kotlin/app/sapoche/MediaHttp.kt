package app.sapoche

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

/** The files of the chat, as the room's server takes and gives them. They are already encrypted: this only moves bytes. */
object MediaHttp {
    private val CODE = Regex("[A-Z0-9]{6}")
    private val ID = Regex("[A-Za-z0-9_-]{22}")
    private val STREAM = "application/octet-stream".toMediaType()

    /** Puts [bytes] at [url] (a path the room gave with its ticket) using the ticket's [token]; false if the server did not take them. */
    suspend fun put(http: OkHttpClient, url: String, token: String, bytes: ByteArray): Boolean = withContext(Dispatchers.IO) {
        // Only the path of a ticket: this must not be a way to send the key of the group to another address
        if (!url.startsWith("/media/")) return@withContext false
        val request = Request.Builder().url("${Config.SERVER}$url&token=$token")
            .put(bytes.toRequestBody(STREAM))
            .apply { Config.authHeaders.forEach { (k, v) -> header(k, v) } }
            .build()
        try {
            http.newCall(request).execute().use { it.isSuccessful }
        } catch (_: IOException) {
            false
        }
    }

    /** The file [m] of room [room]; null when there is none or it cannot be fetched. */
    suspend fun get(http: OkHttpClient, room: String, m: String): ByteArray? = withContext(Dispatchers.IO) {
        val code = room.trim().uppercase()
        if (!CODE.matches(code) || !ID.matches(m)) return@withContext null
        val request = Request.Builder().url("${Config.SERVER}/media/$code/$m")
            .apply { Config.authHeaders.forEach { (k, v) -> header(k, v) } }
            .build()
        try {
            http.newCall(request).execute().use { if (it.isSuccessful) it.body.bytes() else null }
        } catch (_: IOException) {
            null
        }
    }
}
