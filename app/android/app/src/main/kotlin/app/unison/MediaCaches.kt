package app.unison

import android.content.Context
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.ContentMetadataMutations
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

/**
 * The songs kept on disk, in two places under the same key, the video id:
 * - [downloads]: songs the person chose to keep. Nothing ever removes them but the person.
 * - [play]: what was played, so hearing it again costs no data. The oldest goes first once it is full.
 *
 * Bytes of one song must all come from one stream (one itag): mixing two streams makes a file that does
 * not play. So the itag is pinned in the cache's own metadata next to the bytes, and whoever resolves the
 * song must use that stream again (see [pinned] and [app.unison.core.AudioPicker]).
 */
class MediaCaches(
    context: Context,
    playLimitBytes: Long,
    downloadsDir: File = File(context.filesDir, "downloads"),
    playDir: File = File(context.cacheDir, "playcache"),
) {

    private val database = StandaloneDatabaseProvider(context)

    val downloads: SimpleCache = SimpleCache(downloadsDir, NoOpCacheEvictor(), database)
    val play: SimpleCache = SimpleCache(playDir, LeastRecentlyUsedCacheEvictor(playLimitBytes), database)

    fun release() {
        downloads.release()
        play.release()
    }

    /** The stream the bytes kept for [videoId] belong to, looking in the downloads first; null when nothing is pinned. */
    fun pinned(videoId: String): Int? {
        for (cache in listOf(downloads, play)) {
            val itag = cache.getContentMetadata(videoId).get(PIN, -1L)
            if (itag >= 0) return itag.toInt()
        }
        return null
    }

    /** Notes that the bytes of [videoId] in [cache] are from stream [itag]. */
    fun pin(cache: Cache, videoId: String, itag: Int) {
        cache.applyContentMetadataMutations(videoId, ContentMetadataMutations().set(PIN, itag.toLong()))
    }

    /** Throws away whatever was kept for [videoId] in either place, because it belongs to a stream that is gone. */
    fun forget(videoId: String) {
        downloads.removeResource(videoId)
        play.removeResource(videoId)
    }

    /** Whether the whole of [videoId] is on disk, so it can be played without the network. */
    fun isComplete(videoId: String): Boolean = isComplete(downloads, videoId) || isComplete(play, videoId)

    /** Whether the whole of [videoId] was downloaded. */
    fun isDownloaded(videoId: String): Boolean = isComplete(downloads, videoId)

    /** Bytes of [videoId] in the downloads. */
    fun downloadedBytes(videoId: String): Long = downloads.getCachedBytes(videoId, 0, Long.MAX_VALUE).coerceAtLeast(0)

    fun clearPlay() {
        play.keys.toList().forEach(play::removeResource)
    }

    fun clearDownloads() {
        downloads.keys.toList().forEach(downloads::removeResource)
    }

    private fun isComplete(cache: Cache, videoId: String): Boolean {
        val length = ContentMetadata.getContentLength(cache.getContentMetadata(videoId))
        return length > 0 && cache.isCached(videoId, 0, length)
    }

    companion object {
        private const val PIN = "unison.itag"
    }
}
