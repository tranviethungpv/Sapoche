package app.sapoche

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.media3.common.util.UnstableApi
import app.sapoche.sync.LocalSession
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * What a touch on a widget does without opening the app: jump to a song of the queue, or play one of the quick lists.
 * The receiver answers with a short message when it cannot, as a widget has nowhere else to say it.
 */
@UnstableApi
class WidgetActions : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        scope.launch {
            try {
                when (intent.action) {
                    JUMP -> jump(context, intent.getStringExtra(EXTRA_ID).orEmpty())
                    NEXT -> skip(context, next = true)
                    PREVIOUS -> skip(context, next = false)
                    QUICK -> quick(context, intent.getStringExtra(EXTRA_LIST).orEmpty(), intent.getLongExtra(EXTRA_PLAYLIST, 0))
                }
            } catch (e: Exception) {
                EventLog.d("widget", "${intent.action} failed: $e")
            } finally {
                pending.finish()
            }
        }
    }

    private fun jump(context: Context, itemId: String) {
        // Nothing runs when the service is gone: the queue shown is what it was, and there is nothing to jump in
        val group = SapocheApp.group.value ?: return say(context, Widgets.text("Mở Sapoche để phát tiếp", "Open Sapoche to play on"))
        group.requestJump(itemId)
    }

    /** The service's controller, which is started first when it is not running (it stops itself after a while with nothing to play). */
    private suspend fun groupOrStart(context: Context) = SapocheApp.group.value ?: run {
        // The service starts as the first song is asked for, and posts its notification when it plays
        ContextCompat.startForegroundService(context, Intent(context, PlaybackService::class.java))
        withTimeoutOrNull(START_TIMEOUT_MS) { SapocheApp.group.first { it != null } }
    }

    /** Next or previous song: the room's while joined, the personal queue's otherwise, as the buttons of the notification do. */
    private suspend fun skip(context: Context, next: Boolean) {
        val group = groupOrStart(context) ?: return
        if (!group.view.value.snapshot.canSteer) {
            EventLog.d("widget", "skip asked from a widget, not allowed in this room")
            return say(context, Widgets.text("Phòng này không cho đổi bài", "This room does not let guests skip"))
        }
        EventLog.d("widget", if (next) "next asked from a widget" else "previous asked from a widget")
        if (next) group.requestNext() else group.requestPrev()
    }

    private suspend fun quick(context: Context, list: String, playlist: Long) {
        val group = groupOrStart(context) ?: return
        if (group.view.value.roomCode != null) {
            return say(context, Widgets.text("Đang ở phòng: chọn bài trong app", "In a room: pick the songs in the app"))
        }
        val tracks = when (list) {
            LIKED -> SapocheApp.library.liked().map { it.track }
            MIX -> SapocheApp.suggestions.forYou()
            DOWNLOADS -> SapocheApp.library.downloads().filter { it.state == LibraryStore.DONE }.map { it.track }
            PLAYLIST -> SapocheApp.library.playlistTracks(playlist)
            else -> emptyList<TrackRef>()
        }.distinctBy { it.videoId }.take(LocalSession.MAX_QUEUE)
        if (tracks.isEmpty()) return say(context, Widgets.text("Chưa có bài nào ở đây", "Nothing here yet"))
        EventLog.d("widget", "quick list $list: ${tracks.size} songs")
        group.requestClearQueue()
        group.requestAddMany(tracks, false)
    }

    private fun say(context: Context, message: String) = Toast.makeText(context, message, Toast.LENGTH_SHORT).show()

    companion object {
        private const val JUMP = "app.sapoche.widget.JUMP"
        private const val QUICK = "app.sapoche.widget.QUICK"
        private const val NEXT = "app.sapoche.widget.NEXT"
        private const val PREVIOUS = "app.sapoche.widget.PREVIOUS"
        private const val EXTRA_ID = "id"
        private const val EXTRA_LIST = "list"
        private const val EXTRA_PLAYLIST = "playlist"
        private const val START_TIMEOUT_MS = 6_000L

        const val LIKED = "liked"
        const val MIX = "mix"
        const val DOWNLOADS = "downloads"
        const val PLAYLIST = "playlist"

        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

        /** Jumps to the song of the queue with [itemId]; [row] tells the touches of different rows apart. */
        fun jump(context: Context, row: Int, itemId: String): PendingIntent = broadcast(context, 100 + row, Intent(JUMP).putExtra(EXTRA_ID, itemId))

        /** Skips to the next song. */
        fun next(context: Context): PendingIntent = broadcast(context, 300, Intent(NEXT))

        /** Goes back to the previous song. */
        fun previous(context: Context): PendingIntent = broadcast(context, 301, Intent(PREVIOUS))

        /** Plays the quick list [list] (and [playlist], when it is one). */
        fun quick(context: Context, list: String, playlist: Long = 0): PendingIntent =
            broadcast(context, 200 + list.hashCode().and(0xFFFF), Intent(QUICK).putExtra(EXTRA_LIST, list).putExtra(EXTRA_PLAYLIST, playlist))

        private fun broadcast(context: Context, code: Int, intent: Intent): PendingIntent = PendingIntent.getBroadcast(
            context,
            code,
            intent.setClass(context, WidgetActions::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
