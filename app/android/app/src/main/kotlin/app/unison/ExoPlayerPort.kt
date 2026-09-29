package app.unison

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

    init {
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_READY -> resumeWaiting()
                    Player.STATE_ENDED -> onEnded?.invoke()
                }
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                // Only a natural move to the queued successor; our own loads report other reasons
                if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) onAdvanced?.invoke()
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
                load(item, seekToMs)
                return
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Often a stream URL that stopped working: resolve again once before giving up
                if (++attempt >= MAX_LOAD_ATTEMPTS) throw e
                EventLog.d("port", "load of ${item.videoId} failed (${e.message}), resolving again")
                UnisonApp.streams.invalidate(item.videoId)
            }
        }
    }

    private suspend fun load(item: QueueItem, seekToMs: Long) {
        player.playWhenReady = false
        player.setMediaItem(mediaItem(item), seekToMs)
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
        val nextIndex = player.currentMediaItemIndex + 1
        when {
            item == null -> if (count > nextIndex) player.removeMediaItems(nextIndex, count)
            count > nextIndex -> {
                if (player.getMediaItemAt(nextIndex).mediaId != item.videoId) {
                    player.replaceMediaItem(nextIndex, mediaItem(item))
                }
            }
            else -> player.addMediaItem(mediaItem(item))
        }
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

    private fun mediaItem(item: QueueItem) = MediaItem.Builder()
        .setMediaId(item.videoId)
        .setUri("unison:${item.videoId}")
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(item.title)
                .setArtist(item.artist)
                .apply { item.thumb?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                .build(),
        )
        .build()

    private companion object {
        const val MAX_LOAD_ATTEMPTS = 2
        const val LOAD_TIMEOUT_MS = 20_000L
        const val SEEK_TIMEOUT_MS = 8_000L
    }
}
