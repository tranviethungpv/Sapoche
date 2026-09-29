package app.unison

object Config {
    /** Room server; WebSocket rooms live at wss://<host>/room/<CODE>. Set in local.properties. */
    val SERVER: String = BuildConfig.SERVER_URL

    /** Shared secret the server requires, sent with every request. Set in local.properties. */
    private val ROOM_KEY: String = BuildConfig.ROOM_KEY

    /** Headers that every call to the room server must carry. */
    val authHeaders: Map<String, String> = if (ROOM_KEY.isEmpty()) emptyMap() else mapOf("X-Unison-Key" to ROOM_KEY)
}
