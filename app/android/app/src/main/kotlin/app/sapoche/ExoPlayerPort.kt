package app.sapoche

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import app.sapoche.sync.LoadFailure
import app.sapoche.sync.PlayerPort
import app.sapoche.sync.QueueItem
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

    /** The wait is a prepare's, whose failures are its caller's; a seek's are [onError]'s, see [seekTo]. */
    private var waitingToLoad = false

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
                // Told late, after the player moved on: a stop and the next load made within one callback deliver the
                // stop's IDLE once the next load waits, which would fail it for nothing
                if (playbackState != player.playbackState) return
                when (playbackState) {
                    Player.STATE_READY -> resumeWaiting()
                    Player.STATE_ENDED -> onEnded?.invoke()
                    // Whoever stops the player on purpose cancels the load first, so a load still waiting was
                    // stopped by something else: try again now rather than wait out LOAD_TIMEOUT_MS. An error
                    // goes to onPlayerError instead
                    Player.STATE_IDLE -> if (player.playerError == null) failWaiting()
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
                // Told late, after the player was stopped or loaded again: it is about a song that is not there any more
                if (player.playerError == null) return
                val pending = waiting
                if (pending != null && waitingToLoad) {
                    waiting = null
                    pending.resumeWithException(error)
                } else {
                    // A seek waiting for it ends, and whoever owns the queue loads the song again
                    resumeWaiting()
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
                // No network, or a video YouTube will not play: another try would end the same way
                LoadFailure.of(e)?.let { throw it }
                if (++attempt >= MAX_LOAD_ATTEMPTS) throw e
                if (e is NotReady) {
                    // Only slow: the address is fine, and the next try reads what came so far from the disk
                    EventLog.d("port", "load of ${item.videoId} is slow (${e.message}), trying again")
                } else {
                    // Often a stream URL that stopped working: resolve again once before giving up
                    EventLog.d("port", "load of ${item.videoId} failed (${e.message}), resolving again")
                    SapocheApp.streams.invalidate(item.videoId)
                }
                // Bytes that do not read as a song will not read any better the next time: fetch them again
                if (e is PlaybackException && e.errorCode in PARSING_ERRORS) {
                    EventLog.d("port", "what was kept of ${item.videoId} does not read, dropping it")
                    SapocheApp.caches.play.removeResource(item.videoId)
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
        waitingToLoad = true
        try {
            awaitReady(LOAD_TIMEOUT_MS)
        } finally {
            waitingToLoad = false
        }
    }

    override suspend fun seekTo(positionMs: Long) {
        player.seekTo(positionMs) // masks the state as buffering until the seek completes
        try {
            awaitReady(SEEK_TIMEOUT_MS)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // A slow network or none: the player goes on buffering at the new place, and tells of a failure by itself
            EventLog.d("port", "seek to ${positionMs}ms not ready yet: ${e.message}")
        }
    }

    override fun play() {
        // Stopped from outside (a STOP button, a car, a watch) or after a failure: the song is still there, it only needs
        // loading again, or play would do nothing at all
        if (player.playbackState == Player.STATE_IDLE && player.mediaItemCount > 0) player.prepare()
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
                if (existing.mediaId != item.videoId || SapocheMediaSourceFactory.isVideo(existing) != videoOn) {
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
        if (on && item != null && current != null && !SapocheMediaSourceFactory.isVideo(current)) {
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
        return videoOn && loaded != null && !SapocheMediaSourceFactory.isVideo(current)
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
            throw NotReady("Player was not ready after ${timeoutMs}ms")
        }
    }

    /** The player is still buffering, without having failed. */
    private class NotReady(message: String) : IOException(message)

    private fun failWaiting() {
        // A seek has nothing more to wait for
        if (!waitingToLoad) return resumeWaiting()
        val pending = waiting ?: return
        waiting = null
        val from = Throwable().stackTrace.filter { it.className.startsWith("app.sapoche") }.drop(2).take(3)
            .joinToString(" < ") { "${it.className.substringAfterLast('.')}.${it.methodName}" }
            .ifEmpty { "the player itself" }
        pending.resumeWithException(IOException("Player stopped while loading (from $from)"))
    }

    private fun resumeWaiting() {
        val pending = waiting ?: return
        waiting = null
        pending.resume(Unit)
    }

    private fun mediaItem(item: QueueItem, withVideo: Boolean) = MediaItem.Builder()
        .setMediaId(item.videoId)
        .setUri(SapocheMediaSourceFactory.uri(item.videoId, withVideo))
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
