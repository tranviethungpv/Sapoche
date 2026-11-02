package app.sapoche

import android.content.Context
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import org.json.JSONArray

/**
 * The rooms this device has been in, for the car's screen. The list is kept by the app's screens (Flutter's preferences,
 * `recent_rooms`: a JSON list of `{code, name, at}`, newest first); the car only reads it, so the two cannot disagree.
 */
class CarRooms(private val context: Context, private val http: OkHttpClient) {

    /** The recent rooms with how many are in each now; a room the server no longer has is left out, one it cannot reach is kept. */
    suspend fun list(): List<CarRoom> {
        val kept = read()
        return coroutineScope {
            kept.map { room ->
                async {
                    val info = withTimeoutOrNull(INFO_TIMEOUT_MS) { runCatching { RoomInfo.fetch(http, room.code) }.getOrNull() }
                    when {
                        info == null -> room
                        info["exists"] != true -> null
                        else -> room.copy(name = (info["name"] as? String) ?: room.name, members = info["members"] as? Int)
                    }
                }
            }.awaitAll().filterNotNull()
        }
    }

    fun read(): List<CarRoom> = runCatching {
        val raw = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: return emptyList()
        val rooms = JSONArray(raw)
        List(rooms.length()) { rooms.getJSONObject(it) }
            .mapNotNull { json ->
                val code = json.optString("code").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                CarRoom(code, json.optString("name").takeIf { !json.isNull("name") && it.isNotEmpty() }, members = null)
            }
    }.getOrDefault(emptyList())

    private companion object {
        const val FLUTTER_PREFS = "FlutterSharedPreferences"
        const val KEY = "flutter.recent_rooms"
        const val INFO_TIMEOUT_MS = 4_000L
    }
}
