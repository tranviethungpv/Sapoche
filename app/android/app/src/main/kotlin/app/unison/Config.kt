package app.unison

import android.net.Uri

object Config {
    /** Room server; WebSocket rooms live at wss://<host>/room/<CODE>. Set in local.properties. */
    val SERVER: String = BuildConfig.SERVER_URL

    /** Shared secret the server requires, sent with every request. Set in local.properties. */
    private val ROOM_KEY: String = BuildConfig.ROOM_KEY

    /** Headers that every call to the room server must carry. */
    val authHeaders: Map<String, String> = if (ROOM_KEY.isEmpty()) emptyMap() else mapOf("X-Unison-Key" to ROOM_KEY)

    /**
     * The server and key as a link that another phone opens to set itself up, for one that was not built with them
     * (an iPhone). Null when there is no server. It carries the secret, so it is only ever shown to the person, on request.
     */
    fun setupLink(): String? {
        if (SERVER.isEmpty()) return null
        val key = if (ROOM_KEY.isEmpty()) "" else "&key=${Uri.encode(ROOM_KEY)}"
        return "unison://setup?server=${Uri.encode(SERVER)}$key"
    }
}
