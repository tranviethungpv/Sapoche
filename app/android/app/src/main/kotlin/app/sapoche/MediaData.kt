package app.sapoche

import android.net.Uri
import app.sapoche.core.AudioQuality
import app.sapoche.core.OkHttpDownloader
import app.sapoche.sync.LoadFailure
import app.sapoche.sync.LocalMusic
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
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
import java.util.concurrent.TimeUnit

/**
 * Where the player and the downloads read songs from. A song is read from the downloads if it is there,
 * else from what was played before, else from YouTube, and what comes from YouTube while playing is
 * kept for next time. Only the sound is kept; the picture is always fetched.
 */
class MediaData(
    private val caches: MediaCaches,
    private val streams: StreamCache,
    private val maxVideoHeight: () -> Int,
    private val audioQuality: () -> AudioQuality,
    private val device: DeviceMusic,
    private val log: (String) -> Unit = {},
) {

    /**
     * Turns "sapoche:ID" into the real address when the loader opens it. [writeTo] is the cache that will keep
     * the bytes, which is told which stream they are from. The real address is read in short ranges.
     */
    private fun resolving(http: DataSource.Factory, writeTo: Cache) = ResolvingDataSource.Factory(ChunkedDataSource.Factory(http)) { spec ->
        val videoId = spec.uri.schemeSpecificPart
        when (spec.uri.scheme) {
            SapocheMediaSourceFactory.AUDIO_SCHEME -> {
                val pinned = caches.pinned(videoId)
                val pick = streams.getAudio(videoId, pinned, audioQuality())
                if (pinned != null && !pick.honoursPin) {
                    log("$videoId: stream $pinned is gone, what was kept of it is dropped")
                    caches.forget(videoId)
                }
                if (pinned != pick.itag) caches.pin(writeTo, videoId, pick.itag)
                spec.withUri(Uri.parse(pick.url))
            }
            SapocheMediaSourceFactory.VIDEO_SCHEME -> spec.withUri(Uri.parse(streams.getVideo(videoId, maxVideoHeight())))
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
        return DataSource.Factory { Routed(sound.createDataSource(), picture.createDataSource(), device) }
    }

    /**
     * Brings the whole of [videoId] into the downloads and gives back its size; throws when that does not work.
     * Runs until done; cancelling the coroutine stops the transfer and keeps what was written, so the next try goes on from there.
     */
    suspend fun download(videoId: String): Long = withContext(Dispatchers.IO) {
        // The two places must not hold bytes of two different streams of one song
        caches.play.removeResource(videoId)
        val spec = DataSpec.Builder().setUri("${SapocheMediaSourceFactory.AUDIO_SCHEME}:$videoId").setKey(videoId).build()
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
     * Streams go through the resolver's own kind of client, which reaches YouTube from the same address the stream
     * address was signed for (see [app.sapoche.core.OneFamilyDns]). Every request asks for a bounded range, see
     * [ChunkedDataSource]: no default Range header may be set here, as this data source adds the range of a request to
     * it instead of replacing it, and YouTube answers two ranges with 416 or a throttled stream.
     */
    fun httpFactory(listener: TransferListener? = null): OkHttpDataSource.Factory = OkHttpDataSource.Factory(streamClient)
        .setUserAgent(OkHttpDownloader.USER_AGENT)
        .apply { listener?.let(::setTransferListener) }

    private val streamClient = OkHttpDownloader.defaultClient().newBuilder()
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    /**
     * Sound goes to [sound], anything else to [picture]. The sound of a music file on this phone is read from the file
     * itself: it is not in any cache, and needs no resolving.
     */
    private class Routed(private val sound: DataSource, private val picture: DataSource, private val device: DeviceMusic) : DataSource {
        private var active: DataSource? = null
        private val file by lazy { device.fileSource() }

        override fun addTransferListener(listener: TransferListener) {
            sound.addTransferListener(listener)
            picture.addTransferListener(listener)
            file.addTransferListener(listener)
        }

        override fun open(dataSpec: DataSpec): Long {
            val videoId = dataSpec.uri.schemeSpecificPart
            if (dataSpec.uri.scheme == SapocheMediaSourceFactory.AUDIO_SCHEME && LocalMusic.isLocal(videoId)) {
                // A file that is gone or cannot be read will not be there the next time either: the song is skipped
                val uri = device.uriNow(videoId) ?: throw LoadFailure(LoadFailure.Reason.UNPLAYABLE, "The file of $videoId is not on this phone")
                active = file
                try {
                    return file.open(dataSpec.buildUpon().setUri(Uri.parse(uri)).build())
                } catch (e: IOException) {
                    active = null
                    throw LoadFailure(LoadFailure.Reason.UNPLAYABLE, "The file of $videoId cannot be read: ${e.message}", e)
                }
            }
            val source = if (dataSpec.uri.scheme == SapocheMediaSourceFactory.AUDIO_SCHEME) sound else picture
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
        /** The key of a song in the caches is its video id, whatever it was opened as ("sapoche:ID" or "sapoche:ID#video"). */
        val KEY = CacheKeyFactory { spec -> spec.uri.schemeSpecificPart }
    }
}
