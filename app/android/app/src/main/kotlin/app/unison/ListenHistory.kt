package app.unison

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import app.unison.sync.ListenTracker
import app.unison.sync.TrackRef
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Writes a song into the listening history once it has been heard for long enough. It watches the player
 * itself, so it counts the same whether the song came from the personal queue or a room, and whether or
 * not the screen is on. Main thread only.
 */
class ListenHistory(
    private val player: Player,
    private val store: LibraryStore,
    private val scope: CoroutineScope,
    private val log: (String) -> Unit = {},
) : Player.Listener {

    private val handler = Handler(Looper.getMainLooper())
    private val tracker = ListenTracker { id, durationMs -> record(id, durationMs) }

    /** The song being followed; kept whole so its details are not read from a player that has moved on. */
    private var item: MediaItem? = null

    private val due = Runnable {
        tracker.check(now())
        schedule()
    }

    fun start() = player.addListener(this)

    fun stop() {
        player.removeListener(this)
        handler.removeCallbacks(due)
    }

    override fun onEvents(player: Player, events: Player.Events) {
        val ended = player.playbackState == Player.STATE_ENDED
        val next = if (ended) null else player.currentMediaItem
        // A song that ended and is loaded again (repeat one) is a new listen, so the end closes this one
        if (next?.mediaId != item?.mediaId) {
            // Counts the song that is ending, if it just passed the mark, so `item` still has to be that one
            tracker.begin(next?.mediaId, player.duration.coerceAtLeast(0), now())
            item = next
        }
        if (item != null) {
            tracker.setDuration(player.duration.coerceAtLeast(0))
            tracker.setPlaying(player.isPlaying, now())
        }
        schedule()
    }

    private fun schedule() {
        handler.removeCallbacks(due)
        tracker.msUntilHeard(now())?.let { handler.postDelayed(due, it) }
    }

    private fun record(id: String, durationMs: Long) {
        val meta = item?.takeIf { it.mediaId == id }?.mediaMetadata ?: return
        val track = TrackRef(
            videoId = id,
            title = meta.title?.toString().orEmpty(),
            artist = meta.artist?.toString().orEmpty(),
            thumb = meta.artworkUri?.toString(),
            durMs = durationMs,
        )
        log("heard '${track.title}'")
        scope.launch {
            try {
                store.recordListen(track)
            } catch (e: Exception) {
                log("could not write the history: ${e.message}")
            }
        }
    }

    private fun now() = SystemClock.elapsedRealtime()
}
