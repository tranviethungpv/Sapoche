package app.sapoche

import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy

/**
 * Builds the media source for a queue item. A plain item is just its audio stream; one marked with
 * [VIDEO_FRAGMENT] also gets the picture-only stream, played in step with the audio.
 *
 * Both parts are loaded through "sapoche:" style addresses that the data source turns into real URLs
 * when the loader opens them, so nothing here needs the network.
 */
class SapocheMediaSourceFactory(private val delegate: MediaSource.Factory) : MediaSource.Factory {

    override fun setDrmSessionManagerProvider(provider: DrmSessionManagerProvider): MediaSource.Factory = apply {
        delegate.setDrmSessionManagerProvider(provider)
    }

    override fun setLoadErrorHandlingPolicy(policy: LoadErrorHandlingPolicy): MediaSource.Factory = apply {
        delegate.setLoadErrorHandlingPolicy(policy)
    }

    override fun getSupportedTypes(): IntArray = delegate.supportedTypes

    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val audio = delegate.createMediaSource(mediaItem)
        if (!isVideo(mediaItem)) return audio
        val picture = mediaItem.buildUpon().setUri("$VIDEO_SCHEME:${mediaItem.mediaId}").build()
        return MergingMediaSource(delegate.createMediaSource(picture), audio)
    }

    companion object {
        const val AUDIO_SCHEME = "sapoche"
        const val VIDEO_SCHEME = "sapochev"
        const val VIDEO_FRAGMENT = "video"

        fun isVideo(item: MediaItem): Boolean = item.localConfiguration?.uri?.fragment == VIDEO_FRAGMENT

        fun uri(videoId: String, withVideo: Boolean): String =
            if (withVideo) "$AUDIO_SCHEME:$videoId#$VIDEO_FRAGMENT" else "$AUDIO_SCHEME:$videoId"
    }
}
