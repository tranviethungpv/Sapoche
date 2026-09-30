package app.unison

import android.net.Uri
import app.unison.core.OkHttpDownloader
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.ContentMetadata
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException

/**
 * Where the player and the downloads read songs from. A song is read from the downloads if it is there,
 * else from what was played before, else from YouTube, and what comes from YouTube while playing is
 * kept for next time. Only the sound is kept; the picture is always fetched.
 */
class MediaData(
    private val caches: MediaCaches,
    private val streams: StreamCache,
    private val maxVideoHeight: () -> Int,
    private val log: (String) -> Unit = {},
) {

    /**
     * Turns "unison:ID" into the real address when the loader opens it. [writeTo] is the cache that will keep
     * the bytes, which is told which stream they are from.
     */
    private fun resolving(http: DataSource.Factory, writeTo: Cache) = ResolvingDataSource.Factory(http) { spec ->
        val videoId = spec.uri.schemeSpecificPart
        when (spec.uri.scheme) {
            UnisonMediaSourceFactory.AUDIO_SCHEME -> {
                val pinned = caches.pinned(videoId)
                val pick = streams.getAudio(videoId, pinned)
                if (pinned != null && !pick.honoursPin) {
                    log("$videoId: stream $pinned is gone, what was kept of it is dropped")
                    caches.forget(videoId)
                }
                if (pinned != pick.itag) caches.pin(writeTo, videoId, pick.itag)
                spec.withUri(Uri.parse(pick.url))
            }
            UnisonMediaSourceFactory.VIDEO_SCHEME -> spec.withUri(Uri.parse(streams.getVideo(videoId, maxVideoHeight())))
            else -> spec
        }
    }

    /** For the player: sound through the caches, picture straight from YouTube. */
    fun playerFactory(http: DataSource.Factory): DataSource.Factory {
        val played = CacheDataSource.Factory()
            .setCache(caches.play)
            .setCacheKeyFactory(KEY)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            .setUpstreamDataSourceFactory(resolving(http, caches.play))
        val sound = CacheDataSource.Factory()
            .setCache(caches.downloads)
            .setCacheWriteDataSinkFactory(null) // playing never adds to the downloads
            .setCacheKeyFactory(KEY)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            .setUpstreamDataSourceFactory(played)
        val picture = resolving(http, caches.play)
        return DataSource.Factory { Routed(sound.createDataSource(), picture.createDataSource()) }
    }

    /**
     * Brings the whole of [videoId] into the downloads and gives back its size; throws when that does not work.
     * Runs until done; cancelling the coroutine stops the transfer and keeps what was written, so the next try goes on from there.
     */
    suspend fun download(videoId: String): Long = withContext(Dispatchers.IO) {
        // The two places must not hold bytes of two different streams of one song
        caches.play.removeResource(videoId)
        val spec = DataSpec.Builder().setUri("${UnisonMediaSourceFactory.AUDIO_SCHEME}:$videoId").setKey(videoId).build()
        val writer = CacheWriter(downloadSource(httpFactory()), spec, null, null)
        coroutineScope {
            // The transfer blocks its thread, so something else has to notice that this coroutine was cancelled
            val watcher = launch {
                try {
                    awaitCancellation()
                } finally {
                    writer.cancel()
                }
            }
            try {
                writer.cache()
            } finally {
                watcher.cancel()
            }
        }
        val length = ContentMetadata.getContentLength(caches.downloads.getContentMetadata(videoId))
        if (length <= 0 || !caches.downloads.isCached(videoId, 0, length)) {
            throw IOException("$videoId was not all written (length $length)")
        }
        length
    }

    /** For downloading: reads and writes the downloads, and fails loudly when it cannot. */
    fun downloadSource(http: DataSource.Factory): CacheDataSource = CacheDataSource.Factory()
        .setCache(caches.downloads)
        .setCacheKeyFactory(KEY)
        .setUpstreamDataSourceFactory(resolving(http, caches.downloads))
        .createDataSource()

    /**
     * YouTube's servers throttle a plain GET to about real-time speed (~270 kbit/s). ExoPlayer leaves out the Range header
     * when starting at byte 0, so one is always sent; for later seeks the data source replaces it with the exact range.
     */
    fun httpFactory(listener: TransferListener? = null): DefaultHttpDataSource.Factory = DefaultHttpDataSource.Factory()
        .setDefaultRequestProperties(mapOf("Range" to "bytes=0-"))
        .setUserAgent(OkHttpDownloader.USER_AGENT)
        .setConnectTimeoutMs(15_000)
        .setReadTimeoutMs(20_000)
        .setAllowCrossProtocolRedirects(true)
        .apply { listener?.let(::setTransferListener) }

    /** Sound goes to [sound], anything else to [picture]. */
    private class Routed(private val sound: DataSource, private val picture: DataSource) : DataSource {
        private var active: DataSource? = null

        override fun addTransferListener(listener: TransferListener) {
            sound.addTransferListener(listener)
            picture.addTransferListener(listener)
        }

        override fun open(dataSpec: DataSpec): Long {
            val source = if (dataSpec.uri.scheme == UnisonMediaSourceFactory.AUDIO_SCHEME) sound else picture
            active = source
            return source.open(dataSpec)
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int = active!!.read(buffer, offset, length)

        override fun getUri(): Uri? = active?.uri

        override fun getResponseHeaders(): Map<String, List<String>> = active?.responseHeaders ?: emptyMap()

        override fun close() {
            try {
                active?.close()
            } finally {
                active = null
            }
        }
    }

    companion object {
        /** The key of a song in the caches is its video id, whatever it was opened as ("unison:ID" or "unison:ID#video"). */
        val KEY = CacheKeyFactory { spec -> spec.uri.schemeSpecificPart }
    }
}
