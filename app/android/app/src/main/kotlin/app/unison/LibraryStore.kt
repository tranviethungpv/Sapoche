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
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Version 1 is the first; later versions add their steps here, each with a test
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
                "AND video_id NOT IN (SELECT video_id FROM history)",
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
        private const val VERSION = 1
        const val RECENT_LIMIT = 100
        const val HISTORY_KEEP = 2000
    }
}
