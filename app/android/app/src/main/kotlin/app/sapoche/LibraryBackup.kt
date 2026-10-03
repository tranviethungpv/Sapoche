package app.sapoche

import app.sapoche.sync.TrackRef
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * The file a library is saved to and read back from: plain JSON, so that a person can look inside it. Songs are
 * listed once, and likes, playlists and listens point to them by video id.
 */
object LibraryBackup {

    /** The file is not a backup of ours, or is one from a newer app. */
    class FormatException(message: String) : Exception(message)

    fun toJson(backup: LibraryStore.Backup, at: Long): String {
        val songs = LinkedHashMap<String, TrackRef>()
        backup.liked.forEach { songs[it.track.videoId] = it.track }
        backup.listens.forEach { songs[it.track.videoId] = it.track }
        backup.playlists.forEach { p -> p.tracks.forEach { songs[it.videoId] = it } }
        return JSONObject()
            .put("app", APP)
            .put("version", VERSION)
            .put("exportedAt", at)
            .put(
                "songs",
                JSONObject().also { o ->
                    songs.values.forEach {
                        o.put(
                            it.videoId,
                            JSONObject().put("title", it.title).put("artist", it.artist).put("thumb", it.thumb ?: JSONObject.NULL).put("durMs", it.durMs),
                        )
                    }
                },
            )
            .put("liked", JSONArray().also { a -> backup.liked.forEach { a.put(JSONObject().put("id", it.track.videoId).put("at", it.at)) } })
            .put(
                "playlists",
                JSONArray().also { a ->
                    backup.playlists.forEach { p ->
                        a.put(
                            JSONObject().put("name", p.name).put("createdAt", p.createdAt).put("updatedAt", p.updatedAt)
                                .put("songs", JSONArray().also { ids -> p.tracks.forEach { ids.put(it.videoId) } }),
                        )
                    }
                },
            )
            .put("history", JSONArray().also { a -> backup.listens.forEach { a.put(JSONObject().put("id", it.track.videoId).put("at", it.at)) } })
            .toString()
    }

    /** Reads a file written by [toJson]. References to songs the file does not describe are skipped. */
    fun fromJson(text: String): LibraryStore.Backup {
        try {
            val root = JSONObject(text)
            val app = root.optString("app")
            if (app != APP && app != FORMER_APP) throw FormatException("Not a Sapoche backup")
            if (root.optInt("version") > VERSION) throw FormatException("Made by a newer version of Sapoche")
            val table = root.getJSONObject("songs")
            val songs = HashMap<String, TrackRef>()
            for (id in table.keys()) {
                val song = table.getJSONObject(id)
                val title = song.optString("title").take(MAX_TEXT)
                if (id.isBlank() || id.length > MAX_ID || title.isBlank()) continue
                songs[id] = TrackRef(id, title, song.optString("artist").take(MAX_TEXT), song.optString("thumb").takeIf { it.isNotBlank() && !song.isNull("thumb") }, song.optLong("durMs").coerceAtLeast(0))
            }
            fun entries(array: JSONArray?): List<LibraryStore.Entry> = array.objects().mapNotNull {
                songs[it.optString("id")]?.let { track -> LibraryStore.Entry(track, it.optLong("at")) }
            }
            return LibraryStore.Backup(
                liked = entries(root.optJSONArray("liked")),
                playlists = root.optJSONArray("playlists").objects().map { p ->
                    LibraryStore.SavedPlaylist(
                        name = p.optString("name"),
                        createdAt = p.optLong("createdAt"),
                        updatedAt = p.optLong("updatedAt"),
                        tracks = p.optJSONArray("songs")?.let { ids -> (0 until ids.length()).mapNotNull { songs[ids.optString(it)] } }.orEmpty(),
                    )
                },
                listens = entries(root.optJSONArray("history")),
            )
        } catch (e: JSONException) {
            throw FormatException("Not a Sapoche backup")
        }
    }

    private fun JSONArray?.objects(): List<JSONObject> =
        if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

    private const val APP = "sapoche"

    /** What backups say when the app wrote them as Unison: still read, since they are how a library moved to the renamed app. */
    private const val FORMER_APP = "unison"

    private const val VERSION = 1
    private const val MAX_ID = 32
    private const val MAX_TEXT = 300
}
