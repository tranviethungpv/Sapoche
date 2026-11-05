package app.sapoche

import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.PlayerMessage
import androidx.media3.exoplayer.Renderer
import app.sapoche.core.Loudness
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * The player's volume: the song's own factor (see [Loudness]) times the fade of the sleep timer, both of which only
 * ever turn the volume down. Everything but [BookListener] runs on the main thread, where ExoPlayer is used.
 *
 * A song that follows the one playing is turned to its own level by a message to the audio renderer at the very start of
 * that song, which the playing thread delivers: setting the volume when the main thread hears of the change would be a
 * few tens of milliseconds late, and the start of a loud song could be heard at the old level.
 */
class VolumeBalance(
    private val exo: ExoPlayer,
    private val book: LoudnessBook,
    private val scope: CoroutineScope,
    /** Whether songs are to be evened out; the person's choice. */
    private val on: () -> Boolean,
) {
    private var fade = 1f
    private var queuedMessage: PlayerMessage? = null
    private val looked = HashSet<String>()
    private val main = Handler(Looper.getMainLooper())

    init {
        exo.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: androidx.media3.common.MediaItem?, reason: Int) = apply()

            override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) = apply()
        })
        book.onHeard = { id -> main.post { heard(id) } }
    }

    /** The sleep timer's fade: the share (1 is full) of the volume that the loudness of the song allows. */
    fun fade(share: Float) {
        fade = share
        apply()
    }

    /** The choice to even songs out was changed. */
    fun changed() = apply()

    private fun heard(videoId: String) {
        val here = exo.currentMediaItem?.mediaId
        if (videoId == here || videoId == exo.nextMediaId()) apply()
    }

    private fun apply() {
        val id = exo.currentMediaItem?.mediaId
        val volume = fade * factor(id)
        if (volume != exo.volume) EventLog.d("volume", "$id volume=$volume (fade=$fade)")
        exo.volume = volume
        scheduleNext()
    }

    /** The factor of [videoId], 1 until its loudness is known; the library is asked once if this run has not heard it yet. */
    private fun factor(videoId: String?): Float {
        if (videoId == null || !on()) return 1f
        val db = book.of(videoId)
        if (db == null && looked.add(videoId)) {
            scope.launch { book.stored(videoId)?.let { book.onHeard(videoId) } }
        }
        return Loudness.gain(db)
    }

    /** The song behind the current one gets its volume at its first moment, see the class comment. */
    private fun scheduleNext() {
        queuedMessage?.cancel()
        queuedMessage = null
        val next = exo.currentMediaItemIndex + 1
        if (next >= exo.mediaItemCount) return
        val renderer = (0 until exo.rendererCount).firstOrNull { exo.getRendererType(it) == C.TRACK_TYPE_AUDIO }
            ?.let(exo::getRenderer) ?: return
        val volume = fade * factor(exo.getMediaItemAt(next).mediaId)
        EventLog.d("volume", "${exo.getMediaItemAt(next).mediaId} is to start at volume=$volume")
        queuedMessage = exo.createMessage(renderer)
            .setType(Renderer.MSG_SET_VOLUME)
            .setPayload(volume)
            .setPosition(next, 0)
            .setDeleteAfterDelivery(true)
            .send()
    }

    private fun ExoPlayer.nextMediaId(): String? =
        currentMediaItemIndex.plus(1).takeIf { it < mediaItemCount }?.let { getMediaItemAt(it).mediaId }
}
