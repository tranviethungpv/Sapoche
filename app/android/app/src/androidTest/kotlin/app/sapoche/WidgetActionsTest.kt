package app.sapoche

import android.content.Context
import androidx.media3.common.util.UnstableApi
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** What a touch on a widget does, sent as the launcher sends it: through the PendingIntent the widget holds. */
@UnstableApi
class WidgetActionsTest {

    private val context = ApplicationProvider.getApplicationContext<Context>()

    /** Liked now, newer than everything else: a song liked before keeps its old time unless it is let go of first. */
    private suspend fun likeNow(id: String, after: Long) {
        SapocheApp.library.setLiked(song(id), false)
        SapocheApp.library.setLiked(song(id), true, at = System.currentTimeMillis() + after)
    }

    private fun song(id: String) = TrackRef(id, "Title $id", "Artist", null, 200_000)

    private fun waitFor(what: String, done: () -> Boolean) {
        repeat(60) {
            if (done()) return
            Thread.sleep(250)
        }
        throw AssertionError(what)
    }

    /** The queue after a touch on the liked tile, from an empty one: what a previous run left is not mistaken for the answer. */
    private fun likedQueue(): GroupController {
        WidgetActions.quick(context, WidgetActions.LIKED).send()
        waitFor("the service did not start") { SapocheApp.group.value != null }
        val group = SapocheApp.group.value!!
        Thread.sleep(1500)
        InstrumentationRegistry.getInstrumentation().runOnMainSync { group.requestClearQueue() }
        waitFor("the queue did not empty") { group.view.value.local.queue.isEmpty() }
        WidgetActions.quick(context, WidgetActions.LIKED).send()
        waitFor("the queue did not fill") { group.view.value.local.queue.size >= 2 }
        return group
    }

    @Test
    fun aQuickListPutsItsSongsOnTheQueueWithNoRoom() {
        runBlocking {
            // Newer than anything liked before, whatever a previous run left in the library
            likeNow("liked1", 100_000)
            likeNow("liked2", 100_001)
        }
        val group = likedQueue()
        assertEquals(listOf("liked2", "liked1"), group.view.value.local.queue.take(2).map { it.videoId })
    }

    @Test
    fun aTouchOnTheQueueJumpsToThatSong() {
        runBlocking {
            likeNow("a", 10)
            likeNow("b", 11)
            likeNow("c", 12)
        }
        val group = likedQueue()
        val last = group.view.value.local.queue.last()
        WidgetActions.jump(context, 0, last.id).send()
        waitFor("did not jump") { group.view.value.local.current?.id == last.id }
        assertTrue(group.view.value.local.index == group.view.value.local.queue.lastIndex)
    }
}
