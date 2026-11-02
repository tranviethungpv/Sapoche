package app.sapoche

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

/** What the server says about a room before it is joined. */
object RoomInfo {
    private val CODE = Regex("[A-Z0-9]{6}")

    /** The answer as the UI reads it; null when [code] is not a room code or the server cannot be reached. */
    suspend fun fetch(http: OkHttpClient, code: String): Map<String, Any?>? = withContext(Dispatchers.IO) {
        val clean = code.trim().uppercase()
        if (!CODE.matches(clean)) return@withContext null
        val request = Request.Builder().url("${Config.SERVER}/room/$clean/info")
            .apply { Config.authHeaders.forEach { (k, v) -> header(k, v) } }
            .build()
        http.newCall(request).execute().use {
            if (!it.isSuccessful) return@use null
            val json = JSONObject(it.body.string())
            mapOf(
                "exists" to json.optBoolean("exists"),
                "name" to if (json.isNull("name")) null else json.getString("name"),
                "members" to json.optInt("members"),
                "playing" to json.optBoolean("playing"),
                "title" to if (json.isNull("title")) null else json.getString("title"),
                "who" to json.optJSONArray("who")?.let { names -> List(names.length()) { names.optString(it) } }.orEmpty(),
            )
        }
    }
}
