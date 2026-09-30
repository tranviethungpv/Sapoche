package app.unison

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import app.unison.sync.TrackRef
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * What a person keeps in the app: songs they liked and what they listened to. It lives here in the native
 * side, not in the UI, because the playback service records listens while the screen is gone.
 *
 * All of it runs on one thread, in order, so a like tapped right after a listen is written after it.
 * [tracks] holds the details of every song something points to, so lists can be shown without the network.
 */
class LibraryStore(context: Context, name: String? = "library.db") : SQLiteOpenHelper(context, name, null, VERSION) {

    /** A song with the time it was liked or last heard, and how often it was heard. */
    data class Entry(val track: TrackRef, val at: Long, val plays: Int = 0)

    /** Songs YouTube suggested for a seed, and when they were fetched. */
    data class Cached(val tracks: List<TrackRef>, val fetchedAt: Long)

    /** A playlist as listed: its cover is the first song's picture. */
    data class Playlist(val id: Long, val name: String, val count: Int, val thumb: String?, val updatedAt: Long)

    private val io = Executors.newSingleThreadExecutor { Thread(it, "library").apply { isDaemon = true } }.asCoroutineDispatcher()

    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** Emits after every write, so a screen that shows the library can refresh. */
    val changes: SharedFlow<Unit> = _changes.asSharedFlow()

    override fun onConfigure(db: SQLiteDatabase) {
        db.setForeignKeyConstraintsEnabled(true)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE tracks(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, " +
                "thumb TEXT, dur_ms INTEGER NOT NULL)",
        )
        db.execSQL(
            "CREATE TABLE likes(video_id TEXT PRIMARY KEY REFERENCES tracks(video_id), liked_at INTEGER NOT NULL)",
        )
        db.execSQL(
            "CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, video_id TEXT NOT NULL REFERENCES tracks(video_id), " +
                "played_at INTEGER NOT NULL)",
        )
        db.execSQL("CREATE INDEX history_by_song ON history(video_id)")
        createPlaylistTables(db)
        createSuggestionsTable(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Each step brings the database one version forward and has a test in LibraryStoreTest
        if (oldVersion < 2) createPlaylistTables(db)
        if (oldVersion < 3) createSuggestionsTable(db)
    }

    /** What YouTube listed beside a seed song, kept so suggestions show without the network. */
    private fun createSuggestionsTable(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE suggestions(seed_video_id TEXT PRIMARY KEY, json TEXT NOT NULL, fetched_at INTEGER NOT NULL)")
    }

    private fun createPlaylistTables(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, " +
                "created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
        )
        // A song is in a playlist once; position gives the order and may have gaps
        db.execSQL(
            "CREATE TABLE playlist_items(playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE, " +
                "video_id TEXT NOT NULL REFERENCES tracks(video_id), position INTEGER NOT NULL, " +
                "PRIMARY KEY(playlist_id, video_id))",
        )
        db.execSQL("CREATE INDEX playlist_items_by_song ON playlist_items(video_id)")
    }

    // ------------------------------------------------------------------ likes

    /** Liked songs, the most recently liked first. */
    suspend fun liked(): List<Entry> = withContext(io) {
        readableDatabase.rawQuery(
            "SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, l.liked_at, 0 " +
                "FROM likes l JOIN tracks t ON t.video_id = l.video_id ORDER BY l.liked_at DESC, t.video_id",
            null,
        ).use(::entries)
    }

    suspend fun setLiked(track: TrackRef, liked: Boolean, at: Long = System.currentTimeMillis()) = withContext(io) {
        val db = writableDatabase
        db.transaction {
            if (liked) {
                upsertTrack(track)
                // Liking a song that is already liked keeps the time it was first liked
                db.insertWithOnConflict(
                    "likes",
                    null,
                    ContentValues().apply {
                        put("video_id", track.videoId)
                        put("liked_at", at)
                    },
                    SQLiteDatabase.CONFLICT_IGNORE,
                )
            } else {
                db.delete("likes", "video_id = ?", arrayOf(track.videoId))
                dropUnusedTracks()
            }
        }
        _changes.tryEmit(Unit)
    }

    // ------------------------------------------------------------------ history

    /** Songs heard, once each, the one heard last first. */
    suspend fun recent(limit: Int = RECENT_LIMIT): List<Entry> = withContext(io) {
        readableDatabase.rawQuery(
            "SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, MAX(h.played_at) AS last_at, COUNT(*) " +
                "FROM history h JOIN tracks t ON t.video_id = h.video_id " +
                "GROUP BY h.video_id ORDER BY last_at DESC, t.video_id LIMIT ?",
            arrayOf(limit.toString()),
        ).use(::entries)
    }

    /** [track] was heard. Only the last [HISTORY_KEEP] listens are kept. */
    suspend fun recordListen(track: TrackRef, at: Long = System.currentTimeMillis()) = withContext(io) {
        val db = writableDatabase
        db.transaction {
            upsertTrack(track)
            db.insert("history", null, ContentValues().apply {
                put("video_id", track.videoId)
                put("played_at", at)
            })
            db.execSQL(
                "DELETE FROM history WHERE id <= (SELECT id FROM history ORDER BY id DESC LIMIT 1 OFFSET $HISTORY_KEEP)",
            )
            dropUnusedTracks()
        }
        _changes.tryEmit(Unit)
    }

    suspend fun clearHistory() = withContext(io) {
        val db = writableDatabase
        db.transaction {
            db.delete("history", null, null)
            dropUnusedTracks()
        }
        _changes.tryEmit(Unit)
    }

    // ------------------------------------------------------------------ playlists

    /** Playlists, the one changed last first. */
    suspend fun playlists(): List<Playlist> = withContext(io) {
        readableDatabase.rawQuery(
            "SELECT p.id, p.name, p.updated_at, COUNT(i.video_id), " +
                "(SELECT t.thumb FROM playlist_items f JOIN tracks t ON t.video_id = f.video_id " +
                "WHERE f.playlist_id = p.id ORDER BY f.position LIMIT 1) " +
                "FROM playlists p LEFT JOIN playlist_items i ON i.playlist_id = p.id " +
                "GROUP BY p.id ORDER BY p.updated_at DESC, p.id DESC",
            null,
        ).use { c ->
            val list = ArrayList<Playlist>(c.count)
            while (c.moveToNext()) list += Playlist(c.getLong(0), c.getString(1), c.getInt(3), c.getString(4), c.getLong(2))
            list
        }
    }

    /** The songs of a playlist in order; empty when there is no such playlist. */
    suspend fun playlistTracks(id: Long): List<TrackRef> = withContext(io) {
        readableDatabase.rawQuery(
            "SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, 0, 0 " +
                "FROM playlist_items i JOIN tracks t ON t.video_id = i.video_id WHERE i.playlist_id = ? ORDER BY i.position",
            arrayOf(id.toString()),
        ).use { c -> entries(c).map { it.track } }
    }

    /** Makes a playlist, with [tracks] in it if given, and returns its id. */
    suspend fun createPlaylist(name: String, tracks: List<TrackRef> = emptyList(), at: Long = System.currentTimeMillis()): Long =
        withContext(io) {
            val db = writableDatabase
            var id = 0L
            db.transaction {
                id = insertOrThrow(
                    "playlists",
                    null,
                    ContentValues().apply {
                        put("name", cleanName(name))
                        put("created_at", at)
                        put("updated_at", at)
                    },
                )
                appendTracks(id, tracks)
            }
            _changes.tryEmit(Unit)
            id
        }

    suspend fun renamePlaylist(id: Long, name: String, at: Long = System.currentTimeMillis()) = changePlaylist(id, at) {
        update("playlists", ContentValues().apply { put("name", cleanName(name)) }, "id = ?", arrayOf(id.toString()))
    }

    /** Deletes the playlist; the songs stay wherever else they are kept. */
    suspend fun deletePlaylist(id: Long) = withContext(io) {
        val db = writableDatabase
        db.transaction {
            delete("playlists", "id = ?", arrayOf(id.toString()))
            dropUnusedTracks()
        }
        _changes.tryEmit(Unit)
    }

    /** Adds songs at the end; those already in the playlist are left where they are. Returns how many were added. */
    suspend fun addToPlaylist(id: Long, tracks: List<TrackRef>, at: Long = System.currentTimeMillis()): Int {
        var added = 0
        changePlaylist(id, at) { added = appendTracks(id, tracks) }
        return added
    }

    suspend fun removeFromPlaylist(id: Long, videoId: String, at: Long = System.currentTimeMillis()) = changePlaylist(id, at) {
        delete("playlist_items", "playlist_id = ? AND video_id = ?", arrayOf(id.toString(), videoId))
        dropUnusedTracks()
    }

    /** Puts a song at place [toIndex] (0 is the top) of the playlist. */
    suspend fun movePlaylistItem(id: Long, videoId: String, toIndex: Int, at: Long = System.currentTimeMillis()) =
        changePlaylist(id, at) {
            val order = ArrayList<String>()
            rawQuery("SELECT video_id FROM playlist_items WHERE playlist_id = ? ORDER BY position", arrayOf(id.toString())).use {
                while (it.moveToNext()) order += it.getString(0)
            }
            if (!order.remove(videoId)) return@changePlaylist
            order.add(toIndex.coerceIn(0, order.size), videoId)
            order.forEachIndexed { position, video ->
                execSQL("UPDATE playlist_items SET position = ? WHERE playlist_id = ? AND video_id = ?", arrayOf<Any?>(position, id, video))
            }
        }

    /** Runs [change] on one playlist in a transaction, stamps it as changed and announces it. */
    private suspend fun changePlaylist(id: Long, at: Long, change: SQLiteDatabase.() -> Unit) = withContext(io) {
        val db = writableDatabase
        db.transaction {
            change()
            execSQL("UPDATE playlists SET updated_at = ? WHERE id = ?", arrayOf<Any?>(at, id))
        }
        _changes.tryEmit(Unit)
    }

    private fun SQLiteDatabase.appendTracks(id: Long, tracks: List<TrackRef>): Int {
        var next = 0
        var room = 0
        rawQuery("SELECT COALESCE(MAX(position) + 1, 0), COUNT(*) FROM playlist_items WHERE playlist_id = ?", arrayOf(id.toString())).use {
            it.moveToFirst()
            next = it.getInt(0)
            room = MAX_PLAYLIST - it.getInt(1)
        }
        var added = 0
        for (track in tracks) {
            if (room <= 0) break
            upsertTrack(track)
            val row = insertWithOnConflict(
                "playlist_items",
                null,
                ContentValues().apply {
                    put("playlist_id", id)
                    put("video_id", track.videoId)
                    put("position", next)
                },
                SQLiteDatabase.CONFLICT_IGNORE,
            )
            if (row == -1L) continue
            next++
            room--
            added++
        }
        return added
    }

    private fun cleanName(name: String) = name.trim().take(MAX_NAME).ifBlank { "Untitled" }

    // ------------------------------------------------------------------ suggestions

    /**
     * The songs suggestions are built from, at most [SEEDS]: the two liked last, the one heard most in the last
     * two weeks, then whatever was heard last if that leaves room.
     */
    suspend fun suggestionSeeds(now: Long = System.currentTimeMillis()): List<String> = withContext(io) {
        val db = readableDatabase
        fun ids(sql: String, vararg args: Any): List<String> =
            db.rawQuery(sql, args.map { it.toString() }.toTypedArray()).use { c ->
                val list = ArrayList<String>()
                while (c.moveToNext()) list += c.getString(0)
                list
            }
        val seeds = LinkedHashSet<String>()
        seeds += ids("SELECT video_id FROM likes ORDER BY liked_at DESC, video_id LIMIT 2")
        seeds += ids(
            "SELECT video_id FROM history WHERE played_at >= ? GROUP BY video_id " +
                "ORDER BY COUNT(*) DESC, MAX(played_at) DESC LIMIT 1",
            now - SEED_WINDOW_MS,
        )
        seeds += ids("SELECT video_id FROM history GROUP BY video_id ORDER BY MAX(played_at) DESC LIMIT $SEEDS")
        seeds.take(SEEDS)
    }

    /** Ids of the songs heard since [since]. */
    suspend fun heardSince(since: Long): Set<String> = withContext(io) {
        readableDatabase.rawQuery("SELECT DISTINCT video_id FROM history WHERE played_at >= ?", arrayOf(since.toString())).use { c ->
            val set = HashSet<String>()
            while (c.moveToNext()) set += c.getString(0)
            set
        }
    }

    suspend fun likedIds(): Set<String> = withContext(io) {
        readableDatabase.rawQuery("SELECT video_id FROM likes", null).use { c ->
            val set = HashSet<String>()
            while (c.moveToNext()) set += c.getString(0)
            set
        }
    }

    /** What was kept for [seed], or null. */
    suspend fun cachedSuggestions(seed: String): Cached? = withContext(io) {
        readableDatabase.rawQuery("SELECT json, fetched_at FROM suggestions WHERE seed_video_id = ?", arrayOf(seed)).use { c ->
            if (!c.moveToFirst()) return@use null
            val array = try {
                JSONArray(c.getString(0))
            } catch (_: JSONException) {
                return@use null
            }
            Cached(
                (0 until array.length()).map {
                    val o = array.getJSONObject(it)
                    TrackRef(o.getString("v"), o.getString("t"), o.getString("a"), o.optString("i").ifEmpty { null }, o.getLong("d"))
                },
                c.getLong(1),
            )
        }
    }

    suspend fun putSuggestions(seed: String, tracks: List<TrackRef>, at: Long = System.currentTimeMillis()) = withContext(io) {
        val json = JSONArray()
        for (t in tracks) {
            json.put(JSONObject().put("v", t.videoId).put("t", t.title).put("a", t.artist).put("i", t.thumb ?: "").put("d", t.durMs))
        }
        writableDatabase.insertWithOnConflict(
            "suggestions",
            null,
            ContentValues().apply {
                put("seed_video_id", seed)
                put("json", json.toString())
                put("fetched_at", at)
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
        _changes.tryEmit(Unit)
    }

    /** Forgets what was kept for every seed but [seeds]. */
    suspend fun keepSuggestionsFor(seeds: Collection<String>) = withContext(io) {
        val marks = seeds.joinToString(",") { "?" }
        writableDatabase.execSQL("DELETE FROM suggestions WHERE seed_video_id NOT IN ($marks)", arrayOf<Any?>(*seeds.toTypedArray()))
    }

    // ------------------------------------------------------------------ helpers

    /** Adds the song's details, or brings them up to date. A length that is not known does not erase one that is. */
    private fun SQLiteDatabase.upsertTrack(track: TrackRef) {
        val values = ContentValues().apply {
            put("video_id", track.videoId)
            put("title", track.title)
            put("artist", track.artist)
            put("thumb", track.thumb)
            put("dur_ms", track.durMs)
        }
        if (insertWithOnConflict("tracks", null, values, SQLiteDatabase.CONFLICT_IGNORE) != -1L) return
        execSQL(
            "UPDATE tracks SET title = ?, artist = ?, thumb = ?, dur_ms = CASE WHEN ? > 0 THEN ? ELSE dur_ms END WHERE video_id = ?",
            arrayOf<Any?>(track.title, track.artist, track.thumb, track.durMs, track.durMs, track.videoId),
        )
    }

    /**
     * Forgets songs nothing points to any more. Every table that refers to a song must be listed here,
     * or its songs would be lost.
     */
    private fun SQLiteDatabase.dropUnusedTracks() {
        execSQL(
            "DELETE FROM tracks WHERE video_id NOT IN (SELECT video_id FROM likes) " +
                "AND video_id NOT IN (SELECT video_id FROM history) " +
                "AND video_id NOT IN (SELECT video_id FROM playlist_items)",
        )
    }

    private inline fun SQLiteDatabase.transaction(body: SQLiteDatabase.() -> Unit) {
        beginTransaction()
        try {
            body()
            setTransactionSuccessful()
        } finally {
            endTransaction()
        }
    }

    private fun entries(cursor: Cursor): List<Entry> {
        val list = ArrayList<Entry>(cursor.count)
        while (cursor.moveToNext()) {
            list += Entry(
                TrackRef(
                    videoId = cursor.getString(0),
                    title = cursor.getString(1),
                    artist = cursor.getString(2),
                    thumb = cursor.getString(3),
                    durMs = cursor.getLong(4),
                ),
                at = cursor.getLong(5),
                plays = cursor.getInt(6),
            )
        }
        return list
    }

    companion object {
        private const val VERSION = 3
        const val RECENT_LIMIT = 100
        const val HISTORY_KEEP = 2000
        const val MAX_PLAYLIST = 500
        const val MAX_NAME = 60
        const val SEEDS = 3
        private const val SEED_WINDOW_MS = 14L * 24 * 60 * 60 * 1000
    }
}
