package app.sapoche

import androidx.media3.common.Timeline
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.upstream.Allocator

/**
 * [DefaultLoadControl] that waits for more data before playing again after a stall while the network is weak: fewer
 * stalls, each a little longer, instead of one every few seconds. [weak] is read each time the player decides.
 *
 * While the picture is on screen ([pictureShown]) it does not load further than [PICTURE_AHEAD_US] ahead: a song's sound
 * is small and is let to load whole, but its picture is twenty times that, and what is read ahead of a place the
 * person may leave at any moment costs data, memory and a radio that stays on.
 *
 * Every method the player calls is passed on by hand: Kotlin's `by` does not pass on the interface's default methods,
 * and the ones left would throw.
 */
class WeakAwareLoadControl(
    private val delegate: DefaultLoadControl,
    private val weak: () -> Boolean,
    private val pictureShown: () -> Boolean = { false },
) : LoadControl {
    override fun onPrepared(playerId: PlayerId) = delegate.onPrepared(playerId)

    override fun onTracksSelected(parameters: LoadControl.Parameters, trackGroups: TrackGroupArray, trackSelections: Array<out ExoTrackSelection?>) =
        delegate.onTracksSelected(parameters, trackGroups, trackSelections)

    override fun onStopped(playerId: PlayerId) = delegate.onStopped(playerId)

    override fun onReleased(playerId: PlayerId) = delegate.onReleased(playerId)

    override fun getAllocator(playerId: PlayerId): Allocator = delegate.getAllocator(playerId)

    override fun getBackBufferDurationUs(playerId: PlayerId): Long = delegate.getBackBufferDurationUs(playerId)

    override fun retainBackBufferFromKeyframe(playerId: PlayerId): Boolean = delegate.retainBackBufferFromKeyframe(playerId)

    override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
        // Not asked of the delegate then, so that it goes on loading from where it was once the playing has eaten into it
        if (pictureShown() && parameters.bufferedDurationUs >= PICTURE_AHEAD_US) return false
        return delegate.shouldContinueLoading(parameters)
    }

    override fun shouldContinuePreloading(playerId: PlayerId, timeline: Timeline, mediaPeriodId: MediaSource.MediaPeriodId, bufferedDurationUs: Long): Boolean =
        delegate.shouldContinuePreloading(playerId, timeline, mediaPeriodId, bufferedDurationUs)

    override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean {
        if (!delegate.shouldStartPlayback(parameters)) return false
        // The player starts anyway once the whole song is loaded, however little is left
        return !(weak() && parameters.rebuffering) || parameters.bufferedDurationUs >= WEAK_REBUFFER_US
    }

    private companion object {
        const val WEAK_REBUFFER_US = 12_000_000L
        const val PICTURE_AHEAD_US = 60_000_000L
    }
}
