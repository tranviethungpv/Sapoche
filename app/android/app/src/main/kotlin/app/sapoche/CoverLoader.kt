package app.sapoche

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.LruCache
import androidx.media3.common.util.BitmapLoader
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import kotlin.math.min

/**
 * Loads the cover for the notification and the lock screen. The thumbnail a search returns is
 * tiny and shows up blurry there, so this asks for the biggest picture the host has, falls back
 * to the original when there is none, and crops it square like the covers in the app.
 */
@UnstableApi
class CoverLoader : BitmapLoader {

    private val executor = MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor())

    // The notification asks again on every state change; the same few covers should not be fetched again
    private val cache = LruCache<String, Bitmap>(3)

    override fun supportsMimeType(mimeType: String) = mimeType.startsWith("image/")

    override fun decodeBitmap(data: ByteArray): ListenableFuture<Bitmap> = executor.submit<Bitmap> { decode(data) }

    override fun loadBitmap(uri: Uri): ListenableFuture<Bitmap> = executor.submit<Bitmap> {
        val key = uri.toString()
        cache.get(key) ?: load(key).also { cache.put(key, it) }
    }

    private fun load(url: String): Bitmap {
        val sharp = Thumbnails.sharp(url)
        if (sharp == url) return download(url)
        return try {
            download(sharp)
        } catch (e: IOException) {
            download(url) // not every video has the big picture
        }
    }

    private fun download(url: String): Bitmap {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = TIMEOUT_MS
        connection.readTimeout = TIMEOUT_MS
        try {
            return decode(connection.inputStream.use { it.readBytes() })
        } finally {
            connection.disconnect()
        }
    }

    private fun decode(data: ByteArray): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        var sample = 1
        while (min(bounds.outWidth, bounds.outHeight) / (sample * 2) >= SIDE) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val full = BitmapFactory.decodeByteArray(data, 0, data.size, options)
            ?: throw IOException("Not a picture")
        val side = min(full.width, full.height)
        val square = Bitmap.createBitmap(full, (full.width - side) / 2, (full.height - side) / 2, side, side)
        if (square !== full) full.recycle()
        return square
    }

    private companion object {
        const val TIMEOUT_MS = 10_000
        const val SIDE = 720
    }
}
