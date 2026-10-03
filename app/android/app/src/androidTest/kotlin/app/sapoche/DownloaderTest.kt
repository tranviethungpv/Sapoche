package app.sapoche

import androidx.test.core.app.ApplicationProvider
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.IOException

class DownloaderTest {

    private lateinit var store: LibraryStore
    private val fetched = mutableListOf<String>()
    private val broken = mutableSetOf<String>()
    private var stopAt: String? = null

    private val downloader by lazy {
        Downloader(store, fetch = { id ->
            if (id == stopAt) throw CancellationException("the job was stopped")
            if (id in broken) throw IOException("no network")
            fetched += id
            id.length * 100L
        })
    }

    private fun song(id: String) = TrackRef(id, "Title $id", "Artist", null, 200_000)

    @Before
    fun open() {
        store = LibraryStore(ApplicationProvider.getApplicationContext(), name = null)
    }

    @After
    fun close() = store.close()

    @Test
    fun songsAreDownloadedInOrderAndMarkedDone() = runTest {
        store.requestDownloads(listOf(song("a"), song("bb"), song("c")))
        val result = downloader.drain(waiting = false)
        assertEquals(listOf("a", "bb", "c"), fetched)
        assertEquals(3, result.done)
        assertFalse(result.retryLater)
        val list = store.downloads()
        assertTrue(list.all { it.state == LibraryStore.DONE })
        assertEquals(200L, list.first { it.track.videoId == "bb" }.bytes)
    }

    @Test
    fun aFailingSongDoesNotStopTheOthersAndIsTriedAgainLater() = runTest {
        broken += "bb"
        store.requestDownloads(listOf(song("a"), song("bb"), song("c")))
        val result = downloader.drain(waiting = false)
        assertEquals(listOf("a", "c"), fetched)
        assertEquals(2, result.done)
        assertTrue("it has tries left, so the job asks to be run again", result.retryLater)
        assertEquals(LibraryStore.QUEUED, store.downloads().first { it.track.videoId == "bb" }.state)

        repeat(2) { downloader.drain(waiting = false) }
        assertEquals(LibraryStore.FAILED, store.downloads().first { it.track.videoId == "bb" }.state)
        assertFalse("nothing is left to try", downloader.drain(waiting = false).retryLater)
    }

    @Test
    fun aSongThatFailedIsNotTakenAgainWithinTheSameRun() = runTest {
        broken += "a"
        var attempts = 0
        val counting = Downloader(store, fetch = { attempts++; throw IOException("no") })
        store.requestDownloads(listOf(song("a")))
        counting.drain(waiting = false)
        assertEquals(1, attempts)
    }

    @Test
    fun waitingSongsAreOnlyTakenWhenAskedFor() = runTest {
        store.requestDownloads(listOf(song("w")), waiting = true)
        store.requestDownloads(listOf(song("q")))
        assertEquals(1, downloader.drain(waiting = false).done)
        assertEquals(listOf("q"), fetched)
        assertEquals(1, downloader.drain(waiting = true).done)
        assertEquals(listOf("q", "w"), fetched)
    }

    @Test
    fun aJobThatIsStoppedLeavesTheSongOnTheListUntouched() = runTest {
        stopAt = "bb"
        store.requestDownloads(listOf(song("a"), song("bb")))
        try {
            downloader.drain(waiting = false)
        } catch (_: CancellationException) {
        }
        val list = store.downloads().associate { it.track.videoId to it.state }
        assertEquals(mapOf("a" to LibraryStore.DONE, "bb" to LibraryStore.QUEUED), list)
        stopAt = null
        assertEquals(1, downloader.drain(waiting = false).done)
    }

    @Test
    fun anEmptyListIsNothingToDo() = runTest {
        val result = downloader.drain(waiting = false)
        assertEquals(0, result.done)
        assertFalse(result.retryLater)
    }
}
