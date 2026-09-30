package app.unison

import androidx.test.core.app.ApplicationProvider
import app.unison.sync.TrackRef
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** Runs on a phone: the SQL is the phone's own. Each test gets an empty database that lives in memory. */
class LibraryStoreTest {

    private lateinit var store: LibraryStore

    private fun song(id: String, durMs: Long = 200_000) = TrackRef(id, "Title $id", "Artist", "https://img/$id", durMs)

    @Before
    fun open() {
        store = LibraryStore(ApplicationProvider.getApplicationContext(), name = null)
    }

    @After
    fun close() = store.close()

    @Test
    fun likedSongsComeBackNewestFirst() = runTest {
        store.setLiked(song("a"), true, at = 100)
        store.setLiked(song("b"), true, at = 300)
        store.setLiked(song("c"), true, at = 200)
        assertEquals(listOf("b", "c", "a"), store.liked().map { it.track.videoId })
        assertEquals(song("b"), store.liked().first().track)
    }

    @Test
    fun likingTwiceKeepsTheFirstTime() = runTest {
        store.setLiked(song("a"), true, at = 100)
        store.setLiked(song("a"), true, at = 500)
        assertEquals(listOf(100L), store.liked().map { it.at })
    }

    @Test
    fun unlikingRemovesTheSong() = runTest {
        store.setLiked(song("a"), true, at = 1)
        store.setLiked(song("b"), true, at = 2)
        store.setLiked(song("a"), false)
        assertEquals(listOf("b"), store.liked().map { it.track.videoId })
    }

    @Test
    fun aLikedSongKeepsItsDetailsWhenHeard() = runTest {
        store.setLiked(song("a"), true, at = 1)
        store.recordListen(song("a").copy(title = "New title"), at = 2)
        assertEquals("New title", store.liked().single().track.title)
    }

    @Test
    fun anUnknownLengthDoesNotEraseAKnownOne() = runTest {
        store.setLiked(song("a", durMs = 180_000), true, at = 1)
        store.recordListen(song("a", durMs = 0), at = 2)
        assertEquals(180_000L, store.liked().single().track.durMs)
    }

    @Test
    fun recentListsEachSongOnceWithTheLastTimeAndCount() = runTest {
        store.recordListen(song("a"), at = 10)
        store.recordListen(song("b"), at = 20)
        store.recordListen(song("a"), at = 30)
        val recent = store.recent()
        assertEquals(listOf("a", "b"), recent.map { it.track.videoId })
        assertEquals(listOf(30L, 20L), recent.map { it.at })
        assertEquals(listOf(2, 1), recent.map { it.plays })
    }

    @Test
    fun recentHonoursTheLimit() = runTest {
        for (i in 1..5) store.recordListen(song("s$i"), at = i.toLong())
        assertEquals(listOf("s5", "s4"), store.recent(limit = 2).map { it.track.videoId })
    }

    @Test
    fun onlyTheLastListensAreKept() = runTest {
        for (i in 1..LibraryStore.HISTORY_KEEP + 5) store.recordListen(song("s"), at = i.toLong())
        val entry = store.recent().single()
        assertEquals(LibraryStore.HISTORY_KEEP, entry.plays)
        assertEquals((LibraryStore.HISTORY_KEEP + 5).toLong(), entry.at)
    }

    @Test
    fun clearingTheHistoryKeepsLikesAndForgetsTheRest() = runTest {
        store.setLiked(song("a"), true, at = 1)
        store.recordListen(song("a"), at = 2)
        store.recordListen(song("b"), at = 3)
        store.clearHistory()
        assertEquals(emptyList<String>(), store.recent().map { it.track.videoId })
        assertEquals(listOf("a"), store.liked().map { it.track.videoId })
        // The song that was only in the history is gone, and can come back
        store.recordListen(song("b"), at = 4)
        assertEquals(listOf("b"), store.recent().map { it.track.videoId })
    }

    @Test
    fun aSongUnlikedButStillInTheHistoryIsKept() = runTest {
        store.setLiked(song("a"), true, at = 1)
        store.recordListen(song("a"), at = 2)
        store.setLiked(song("a"), false)
        assertEquals("Title a", store.recent().single().track.title)
    }

    @Test
    fun everyWriteIsAnnounced() = runTest {
        val seen = mutableListOf<Unit>()
        backgroundScope.launch(Dispatchers.Unconfined) { store.changes.collect { seen += it } }
        store.setLiked(song("a"), true)
        store.recordListen(song("a"))
        store.clearHistory()
        assertEquals(3, seen.size)
    }
}
