package app.sapoche

import android.app.Activity
import android.content.Intent
import android.net.Uri
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Saves the library to a file the person chooses and adds one back from a file. The system's own file picker
 * does the choosing, so the app needs no storage permission and the file can go anywhere, a cloud drive included.
 */
class BackupFiles(private val activity: Activity, private val library: LibraryStore) {

    private var waiting: CompletableDeferred<Uri?>? = null

    /** Writes the library to a new file. Gives back what was written, or null when the person backed out. */
    suspend fun export(): LibraryStore.Restored? {
        val backup = library.backup()
        val text = LibraryBackup.toJson(backup, System.currentTimeMillis())
        val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
        val uri = choose(
            Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("application/json")
                .putExtra(Intent.EXTRA_TITLE, "sapoche-library-$day.json"),
        ) ?: return null
        withContext(Dispatchers.IO) {
            val out = activity.contentResolver.openOutputStream(uri, "wt") ?: error("Could not write the file")
            out.use { it.write(text.toByteArray()) }
        }
        return LibraryStore.Restored(backup.liked.size, backup.playlists.size, backup.listens.size, backup.skippedLocal)
    }

    /** Adds what a chosen file holds to the library. Gives back how much was new, or null when the person backed out. */
    suspend fun import(): LibraryStore.Restored? {
        val uri = choose(
            Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*"),
        ) ?: return null
        val text = withContext(Dispatchers.IO) {
            val input = activity.contentResolver.openInputStream(uri) ?: error("Could not read the file")
            val bytes = input.use { it.readUpTo(MAX_BYTES + 1) }
            if (bytes.size > MAX_BYTES) throw LibraryBackup.FormatException("Too big to be a Sapoche backup")
            String(bytes)
        }
        return library.restore(LibraryBackup.fromJson(text))
    }

    /** The file picker closed; called by the activity. */
    fun onResult(resultCode: Int, data: Intent?) {
        waiting?.complete(data?.data.takeIf { resultCode == Activity.RESULT_OK })
        waiting = null
    }

    private suspend fun choose(intent: Intent): Uri? {
        val answer = CompletableDeferred<Uri?>()
        waiting?.complete(null)
        waiting = answer
        activity.startActivityForResult(intent, REQUEST)
        return answer.await()
    }

    /** At most [limit] bytes (`readNBytes` needs Android 13). */
    private fun InputStream.readUpTo(limit: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        while (out.size() < limit) {
            val n = read(chunk, 0, minOf(chunk.size, limit - out.size()))
            if (n < 0) break
            out.write(chunk, 0, n)
        }
        return out.toByteArray()
    }

    companion object {
        const val REQUEST = 4711
        private const val MAX_BYTES = 16 * 1024 * 1024
    }
}
