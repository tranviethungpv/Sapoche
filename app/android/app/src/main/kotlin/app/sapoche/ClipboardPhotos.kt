package app.sapoche

import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * The pictures on the clipboard, for the chat to send. The system keeps a copied picture as a link to the app that holds
 * it, one per picture, so a clip can carry several; reading one needs nothing more than asking the clipboard.
 */
class ClipboardPhotos(private val context: Context) {

    /** A picture read off the clipboard: the file as it is, or as a JPEG/PNG where the app cannot read its format. */
    class Photo(val name: String, val bytes: ByteArray)

    private val clipboard get() = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    /** Whether the clipboard holds a picture. Looks at the kinds of what is there only, so the system tells nobody. */
    fun hasPhotos(): Boolean {
        val description = clipboard.primaryClipDescription ?: return false
        return (0 until description.mimeTypeCount).any { description.getMimeType(it).startsWith("image/") }
    }

    /** The pictures on the clipboard, in order; none when it holds words or nothing. */
    suspend fun read(): List<Photo> = withContext(Dispatchers.IO) {
        val clip = clipboard.primaryClip ?: return@withContext emptyList()
        val photos = ArrayList<Photo>()
        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
            photoAt(context.contentResolver, uri)?.let(photos::add)
            if (photos.size >= MAX) break
        }
        photos
    }

    private fun photoAt(resolver: ContentResolver, uri: Uri): Photo? {
        // A link to anything but a picture (a file, a contact) is not ours to read
        if (resolver.getType(uri)?.startsWith("image/", ignoreCase = true) == false) return null
        val bytes = try {
            resolver.openInputStream(uri)?.use(::readLimited)
        } catch (_: Exception) {
            // Gone, or the app that held it does not let it be read
            null
        } ?: return null
        if (bytes.isEmpty()) return null
        val name = uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "pasted"
        return if (isReadByApp(bytes)) Photo(name, bytes) else convert(name, bytes)
    }

    /** All of [input], or null when it is more than [MAX_BYTES]. */
    private fun readLimited(input: InputStream): ByteArray? {
        val out = ByteArrayOutputStream()
        val chunk = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(chunk)
            if (n < 0) return out.toByteArray()
            out.write(chunk, 0, n)
            if (out.size() > MAX_BYTES) return null
        }
    }

    /** Whether [b] starts as a JPEG, PNG, GIF, WebP or BMP: the app reads these itself, and a GIF that moves must not be touched. */
    private fun isReadByApp(b: ByteArray): Boolean {
        if (b.size < 12) return false
        fun at(i: Int, text: String) = text.indices.all { b[i + it] == text[it].code.toByte() }
        return (b[0] == 0xFF.toByte() && b[1] == 0xD8.toByte() && b[2] == 0xFF.toByte()) ||
            (b[0] == 0x89.toByte() && at(1, "PNG")) || at(0, "GIF8") || at(0, "BM") || (at(0, "RIFF") && at(8, "WEBP"))
    }

    /** What the picture says in a format the app does not read (HEIC, AVIF...) as a picture it does, or null. */
    private fun convert(name: String, bytes: ByteArray): Photo? {
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        val out = ByteArrayOutputStream()
        // PNG keeps what is see-through; the app lays it on white when it makes the picture ready
        val format = if (bitmap.hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
        bitmap.compress(format, 95, out)
        bitmap.recycle()
        return Photo(name, out.toByteArray())
    }

    private companion object {
        /** More than the chat has room for in a message; the rest is not read. */
        const val MAX = 10

        /** A picture bigger than this is not read: the chat shrinks pictures, and a GIF can be 3 MB at most. */
        const val MAX_BYTES = 40 * 1024 * 1024
    }
}
