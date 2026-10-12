package app.sapoche

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import app.sapoche.sync.LocalFile
import app.sapoche.sync.LocalMusic
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import androidx.media3.datasource.ContentDataSource
import androidx.media3.datasource.DataSource
import java.io.ByteArrayOutputStream

/**
 * The music files on this phone, as the system's own music library lists them: the system has read their tags already,
 * so finding them is one query rather than opening each file. The person is only asked to allow it when they open the
 * list. The files are played and shown from where they are; nothing is copied.
 */
class DeviceMusic(private val context: Context, private val library: LibraryStore) {

    private val prefs = context.getSharedPreferences("sapoche", Context.MODE_PRIVATE)

    private var waiting: CompletableDeferred<Unit>? = null

    private val permission =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_EXTERNAL_STORAGE

    /**
     * `granted`; `ask` (not asked yet, or asked and not refused for good); `blocked` (refused for good: only the phone's
     * settings can change that).
     */
    fun access(activity: Activity?): String = when {
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED -> "granted"
        !prefs.getBoolean(KEY_ASKED, false) -> "ask"
        activity?.shouldShowRequestPermissionRationale(permission) == true -> "ask"
        else -> "blocked"
    }

    /** Asks the person to allow reading their music; gives back the access afterwards. */
    suspend fun request(activity: Activity): String {
        if (access(activity) == "granted") return "granted"
        val answer = CompletableDeferred<Unit>()
        waiting?.complete(Unit)
        waiting = answer
        prefs.edit().putBoolean(KEY_ASKED, true).apply()
        activity.requestPermissions(arrayOf(permission), REQUEST)
        answer.await()
        return access(activity)
    }

    /** The permission dialog closed; called by the activity. */
    fun onPermissionResult(requestCode: Int) {
        if (requestCode != REQUEST) return
        waiting?.complete(Unit)
        waiting = null
    }

    /** Opens the phone's settings page of this app, where a refusal for good can be undone. */
    fun openSettings(activity: Activity) {
        activity.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    /** Reads the system's list and brings the library up to date with it. Gives back how many music files are there. */
    suspend fun scan(): Int {
        val started = android.os.SystemClock.elapsedRealtime()
        val found = withContext(Dispatchers.IO) { query() }
        val read = android.os.SystemClock.elapsedRealtime()
        val total = library.applyLocalScan(found)
        EventLog.d("local", "scan: ${found.size} files read in ${read - started} ms, stored in ${android.os.SystemClock.elapsedRealtime() - read} ms")
        return total
    }

    private fun query(): List<LocalFile> {
        if (context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) return emptyList()
        val q = Build.VERSION.SDK_INT >= 29
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.DISPLAY_NAME,
            // Where the file is: the folder and the volume on API 29 and up, the whole path before
            if (q) MediaStore.Audio.Media.RELATIVE_PATH else MediaStore.Audio.Media.DATA,
        )
        val files = ArrayList<LocalFile>()
        context.contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection,
            "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.DURATION} >= ?",
            arrayOf(LocalMusic.MIN_MS.toString()),
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val name = c.getString(8).orEmpty()
                val place = c.getString(9).orEmpty()
                val title = c.getString(1)?.takeIf { it.isNotBlank() } ?: name.substringBeforeLast('.').ifBlank { name }
                // A file with no artist has none: the screens leave the line out, and no taste is built on "unknown"
                val artist = c.getString(2)?.takeIf { it.isNotBlank() && it != MediaStore.UNKNOWN_STRING }.orEmpty()
                files += LocalFile(
                    key = if (q) "$place$name" else place,
                    uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id).toString(),
                    title = title,
                    artist = artist,
                    album = c.getString(3)?.takeIf { it.isNotBlank() && it != MediaStore.UNKNOWN_STRING }.orEmpty(),
                    durMs = c.getLong(4),
                    mime = c.getString(6).orEmpty(),
                    size = c.getLong(5),
                    addedAt = c.getLong(7) * 1000,
                )
            }
        }
        return files
    }

    /** Reads a music file by its address. */
    fun fileSource(): DataSource = ContentDataSource(context)

    /** Where the file of [videoId] is, asked of the library and waited for: the player's loader thread is no place that minds. */
    fun uriNow(videoId: String): String? = runBlocking { library.localUri(videoId) }

    /** Pictures read lately, so that a notification and the player do not have each file opened again; kept for the few songs in play. */
    private val recent = android.util.LruCache<String, ByteArray>(4)

    /** The picture inside the file of [videoId] as JPEG or PNG bytes, or null when it has none or the file is gone. */
    suspend fun cover(videoId: String): ByteArray? {
        recent.get(videoId)?.let { return it }
        val uri = library.localUri(videoId)?.let(Uri::parse) ?: return null
        return withContext(Dispatchers.IO) { cover(context, uri) }?.also { recent.put(videoId, it) }
    }

    /** The picture of [videoId] if it was read lately; never opens a file. */
    fun coverIfRead(videoId: String): ByteArray? = recent.get(videoId)

    /** [cover], waited for; for the loader thread of the notification. */
    fun coverNow(videoId: String): ByteArray? = runBlocking { cover(videoId) }

    companion object {
        const val REQUEST = 4712
        private const val KEY_ASKED = "local_asked"
        private const val COVER_SIDE = 512

        /** The picture inside the music file at [uri] as bytes, or null. */
        fun cover(context: Context, uri: Uri): ByteArray? = try {
            if (Build.VERSION.SDK_INT >= 29) {
                val bitmap = context.contentResolver.loadThumbnail(uri, Size(COVER_SIDE, COVER_SIDE), null)
                ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 88, it) }.toByteArray()
            } else {
                // release(), not use: close() is only there from API 29
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(context, uri)
                    retriever.embeddedPicture
                } finally {
                    retriever.release()
                }
            }
        } catch (_: Exception) {
            null
        }
    }
}
