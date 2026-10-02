package app.unison

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import app.unison.sync.PlayerPort
import app.unison.sync.QueueItem
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Lets the group session drive an ExoPlayer.
 *
 * Everything here runs on the main thread, which is also where ExoPlayer must be accessed; the
 * group session's coroutine scope is bound to the main dispatcher for that reason.
 */
class ExoPlayerPort(private val player: ExoPlayer) : PlayerPort {

    override var onEnded: (() -> Unit)? = null
    override var onError: ((Exception) -> Unit)? = null
    override var onAdvanced: (() -> Unit)? = null

    /** Set while a prepare or seek is waiting for the player to become ready. */
    private var waiting: CancellableContinuation<Unit>? = null

    /** The song the player is on and the one queued behind it, so either can be rebuilt with or without the picture. */
    private var loaded: QueueItem? = null
    private var queuedNext: QueueItem? = null

    /** Items are loaded with their picture while this is on. */
    private var videoOn = false

    /** The picture is actually being shown, so it is worth downloading and decoding. */
    private var videoVisible = false

    init {
        applyVideoSelection()
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_READY -> resumeWaiting()
                    Player.STATE_ENDED -> onEnded?.invoke()
                }
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                // Only a natural move to the queued successor; our own loads report other reasons
                if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) {
                    loaded = queuedNext
                    queuedNext = null
                    onAdvanced?.invoke()
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                val pending = waiting
                if (pending != null) {
                    waiting = null
                    pending.resumeWithException(error)
                } else {
                    onError?.invoke(error)
                }
            }
        })
    }

    override suspend fun prepare(item: QueueItem, seekToMs: Long) {
        var attempt = 0
        while (true) {
            try {
                // A song whose picture cannot be had still plays: the last try is sound only
                load(item, seekToMs, withVideo = videoOn && attempt < MAX_LOAD_ATTEMPTS - 1)
                return
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Often a stream URL that stopped working: resolve again once before giving up
                if (++attempt >= MAX_LOAD_ATTEMPTS) throw e
                EventLog.d("port", "load of ${item.videoId} failed (${e.message}), resolving again")
                UnisonApp.streams.invalidate(item.videoId)
                // Bytes that do not read as a song will not read any better the next time: fetch them again
                if (e is PlaybackException && e.errorCode in PARSING_ERRORS) {
                    EventLog.d("port", "what was kept of ${item.videoId} does not read, dropping it")
                    UnisonApp.caches.play.removeResource(item.videoId)
                }
            }
        }
    }

    private suspend fun load(item: QueueItem, seekToMs: Long, withVideo: Boolean) {
        player.playWhenReady = false
        loaded = item
        queuedNext = null
        player.setMediaItem(mediaItem(item, withVideo), seekToMs)
        player.prepare()
        awaitReady(LOAD_TIMEOUT_MS)
    }

    override suspend fun seekTo(positionMs: Long) {
        player.seekTo(positionMs) // masks the state as buffering until the seek completes
        awaitReady(SEEK_TIMEOUT_MS)
    }

    override fun play() {
        player.play()
    }

    override fun pause() {
        player.pause()
    }

    override fun stop() {
        loaded = null
        queuedNext = null
        player.stop()
        player.clearMediaItems()
    }

    override fun setSpeed(speed: Float) {
        // Keep the pitch untouched, otherwise small speed corrections would be audible
        if (player.playbackParameters.speed != speed) {
            player.playbackParameters = PlaybackParameters(speed, 1f)
        }
    }

    override fun setNext(item: QueueItem?) {
        val count = player.mediaItemCount
        if (count == 0) return
        queuedNext = item
        val nextIndex = player.currentMediaItemIndex + 1
        when {
            item == null -> if (count > nextIndex) player.removeMediaItems(nextIndex, count)
            count > nextIndex -> {
                val existing = player.getMediaItemAt(nextIndex)
                if (existing.mediaId != item.videoId || UnisonMediaSourceFactory.isVideo(existing) != videoOn) {
                    player.replaceMediaItem(nextIndex, mediaItem(item, videoOn))
                }
            }
            else -> player.addMediaItem(mediaItem(item, videoOn))
        }
    }

    /**
     * Play songs with their picture from now on, or sound only. Turning it on for a song that was
     * loaded without one loads it again at the same place, which costs a moment of silence.
     */
    fun setVideoMode(on: Boolean) {
        if (videoOn == on) return
        videoOn = on
        val item = loaded
        val current = player.currentMediaItem
        if (on && item != null && current != null && !UnisonMediaSourceFactory.isVideo(current)) {
            val position = player.currentPosition
            val play = player.playWhenReady
            player.setMediaItem(mediaItem(item, true), position)
            player.prepare()
            player.playWhenReady = play
        }
        queuedNext?.let { setNext(it) } // the next song follows suit
        applyVideoSelection()
    }

    /**
     * The picture is wanted but the song plays without one: it could not be had, so it was loaded as sound only. The
     * screen shows the cover then, rather than waiting for a picture that is not coming.
     */
    fun pictureMissing(): Boolean {
        val current = player.currentMediaItem ?: return false
        return videoOn && loaded != null && !UnisonMediaSourceFactory.isVideo(current)
    }

    /** Whether the picture is on screen. Off, the picture stream is neither downloaded nor decoded. */
    fun setVideoVisible(visible: Boolean) {
        if (videoVisible == visible) return
        videoVisible = visible
        applyVideoSelection()
    }

    private fun applyVideoSelection() {
        val enabled = videoOn && videoVisible
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, !enabled)
            .build()
    }

    override fun positionMs(): Long = player.currentPosition

    override fun isPlaying(): Boolean = player.isPlaying

    private suspend fun awaitReady(timeoutMs: Long) {
        if (player.playbackState == Player.STATE_READY) return
        val result = withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine { cont ->
                waiting = cont
                cont.invokeOnCancellation { if (waiting === cont) waiting = null }
            }
        }
        if (result == null) {
            waiting = null
            throw IOException("Player was not ready after ${timeoutMs}ms")
        }
    }

    private fun resumeWaiting() {
        val pending = waiting ?: return
        waiting = null
        pending.resume(Unit)
    }

    private fun mediaItem(item: QueueItem, withVideo: Boolean) = MediaItem.Builder()
        .setMediaId(item.videoId)
        .setUri(UnisonMediaSourceFactory.uri(item.videoId, withVideo))
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(item.title)
                .setArtist(item.artist)
                .apply { item.thumb?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                .build(),
        )
        .build()

    private companion object {
        const val MAX_LOAD_ATTEMPTS = 3
        const val LOAD_TIMEOUT_MS = 20_000L
        const val SEEK_TIMEOUT_MS = 8_000L
        val PARSING_ERRORS = PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED..PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED
    }
}
