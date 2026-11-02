package app.sapoche

import android.content.Context
import android.net.Uri

object Config {
    /** Room server; WebSocket rooms live at wss://<host>/room/<CODE>. Set in sapoche.properties. */
    val SERVER: String = BuildConfig.SERVER_URL

    /** The key this build carries; empty in a build made to be shared in public, which is given its key by a setup link. */
    private val BUILT_KEY: String = BuildConfig.ROOM_KEY

    private const val PREFS = "sapoche"
    private const val KEY_SETUP = "setup_key"
    private lateinit var prefs: android.content.SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    /** Shared secret the server requires, sent with every request: the one built in, else the one a setup link gave. */
    private val ROOM_KEY: String get() = BUILT_KEY.ifEmpty { prefs.getString(KEY_SETUP, null).orEmpty() }

    /** Headers that every call to the room server must carry. */
    val authHeaders: Map<String, String> get() = if (ROOM_KEY.isEmpty()) emptyMap() else mapOf("X-Sapoche-Key" to ROOM_KEY)

    /** A build for the public has no key in it and is not usable before a setup link brings one. */
    val isSet: Boolean get() = !BuildConfig.NEEDS_SETUP || ROOM_KEY.isNotEmpty()

    /** Keeps the key of a setup link, for a build that has none of its own. */
    fun setKey(key: String) {
        prefs.edit().putString(KEY_SETUP, key.trim()).apply()
    }

    /**
     * The server and key as a link that another phone opens to set itself up, for one that was not built with them
     * (an iPhone, or the build for the public). Null when there is no server. It carries the secret, so it is only ever
     * shown to the person, on request.
     */
    fun setupLink(): String? {
        if (SERVER.isEmpty()) return null
        val key = if (ROOM_KEY.isEmpty()) "" else "&key=${Uri.encode(ROOM_KEY)}"
        return "sapoche://setup?server=${Uri.encode(SERVER)}$key"
    }
}
