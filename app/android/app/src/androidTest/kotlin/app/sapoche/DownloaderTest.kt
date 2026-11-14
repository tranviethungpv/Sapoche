package app.sapoche

import androidx.test.core.app.ApplicationProvider
import app.sapoche.sync.LoadFailure
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
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
    private val gone = mutableSetOf<String>()
    private val offline = mutableSetOf<String>()
    private var stopAt: String? = null

    private val downloader by lazy {
        Downloader(store, fetch = { id ->
            if (id == stopAt) throw CancellationException("the job was stopped")
            if (id in broken) throw IOException("no network")
            if (id in gone) throw LoadFailure(LoadFailure.Reason.UNPLAYABLE, "$id cannot be played")
            if (id in offline) throw LoadFailure(LoadFailure.Reason.OFFLINE, "No network to get $id")
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
    fun aSongYouTubeWillNotGiveOutIsSetAsideAtOnceAndNotTriedAgainLater() = runTest {
        gone += "bb"
        store.requestDownloads(listOf(song("a"), song("bb"), song("c")))
        val result = downloader.drain(waiting = false)
        assertEquals(listOf("a", "c"), fetched)
        assertEquals(2, result.done)
        assertFalse("nothing to try again later", result.retryLater)
        assertEquals(LibraryStore.UNAVAILABLE, store.downloads().first { it.track.videoId == "bb" }.state)

        // The liked songs saved by themselves do not wake it up; the person asking does
        store.requestDownloads(listOf(song("bb")), waiting = true)
        assertEquals(LibraryStore.UNAVAILABLE, store.downloads().first { it.track.videoId == "bb" }.state)
        store.requestDownloads(listOf(song("bb")))
        assertEquals(LibraryStore.QUEUED, store.downloads().first { it.track.videoId == "bb" }.state)
    }

    @Test
    fun noNetworkIsNotTakenForAVideoYouTubeWillNotGiveOut() = runTest {
        offline += "a"
        store.requestDownloads(listOf(song("a")))
        val result = downloader.drain(waiting = false)
        assertTrue(result.retryLater)
        assertEquals(LibraryStore.QUEUED, store.downloads().single().state)
    }

    @Test
    fun withoutInternetTheRunStopsAndNoTryOfTheSongsIsUsedUp() = runTest {
        var internet = false
        val attempts = mutableListOf<String>()
        val down = Downloader(store, fetch = { id -> attempts += id; throw IOException("Unable to resolve host") }, online = { internet })
        store.requestDownloads(listOf(song("a"), song("bb"), song("c")))
        repeat(5) {
            val result = down.drain(waiting = false)
            assertTrue(result.retryLater)
            assertEquals(0, result.done)
        }
        assertEquals("one song is tried per run, the others are left alone", listOf("a", "a", "a", "a", "a"), attempts)
        // Five runs without internet, and every song is as it was: still queued, with all its tries
        assertTrue(store.downloads().all { it.state == LibraryStore.QUEUED })
        internet = true
        attempts.clear()
        val fine = Downloader(store, fetch = { id -> attempts += id; 100L }, online = { true })
        assertEquals(3, fine.drain(waiting = false).done)
        assertTrue(store.downloads().all { it.state == LibraryStore.DONE })
    }

    @Test
    fun aHiccupIsTriedAgainInTheSameRunAndTheSongIsDoneWithoutUsingATry() = runTest {
        var failures = 2
        val flaky = Downloader(store, fetch = { id -> if (failures-- > 0) throw java.net.SocketTimeoutException("timeout") else id.length * 100L })
        store.requestDownloads(listOf(song("a")))
        val result = flaky.drain(waiting = false)
        assertEquals(1, result.done)
        assertFalse(result.retryLater)
        assertEquals(LibraryStore.DONE, store.downloads().single().state)
    }

    @Test
    fun aSongThatKeepsFailingUsesUpOneTryPerRunNotPerQuickRetry() = runTest {
        val failing = Downloader(store, fetch = { throw java.net.SocketTimeoutException("timeout") })
        store.requestDownloads(listOf(song("a")))
        assertTrue(failing.drain(waiting = false).retryLater)
        assertEquals(LibraryStore.QUEUED, store.downloads().single().state)
        failing.drain(waiting = false)
        assertEquals(LibraryStore.QUEUED, store.downloads().single().state)
        assertFalse(failing.drain(waiting = false).retryLater)
        assertEquals("three runs, three tries", LibraryStore.FAILED, store.downloads().single().state)
    }

    @Test
    fun noRoomOnThePhoneStopsTheRunAndPutsTheSongsToFailedAtOnce() = runTest {
        val attempts = mutableListOf<String>()
        val full = Downloader(store, fetch = { id ->
            attempts += id
            if (id == "bb") throw IOException("write failed: ENOSPC (No space left on device)")
            100L
        })
        store.requestDownloads(listOf(song("a"), song("bb"), song("c"), song("d")))
        val result = full.drain(waiting = false)
        assertEquals("after the song that did not fit, the others are not tried", listOf("a", "bb"), attempts)
        assertEquals(1, result.done)
        assertFalse("trying again is no use until there is room", result.retryLater)
        val states = store.downloads().associate { it.track.videoId to it.state }
        assertEquals(mapOf("a" to LibraryStore.DONE, "bb" to LibraryStore.FAILED, "c" to LibraryStore.FAILED, "d" to LibraryStore.FAILED), states)
        val batch = full.progress.value
        assertEquals(1, batch.done)
        assertEquals(3, batch.failed)

        // Once there is room, the person tries them again, and they go
        val roomy = Downloader(store, fetch = { id -> 100L })
        store.requestDownloads(listOf(song("bb"), song("c"), song("d")))
        assertEquals(3, roomy.drain(waiting = false).done)
    }

    @Test
    fun noRoomIsToldFromTheWayTheCacheWrapsIt() {
        assertTrue(Downloader.noSpace(IOException("write failed: ENOSPC (No space left on device)")))
        assertTrue(Downloader.noSpace(RuntimeException("x", IOException("y", IOException("No space left on device")))))
        assertFalse(Downloader.noSpace(IOException("Unable to resolve host")))
        assertFalse(Downloader.noSpace(IOException()))
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
        assertEquals("one go and the quick retries, and no more in this run", 1 + Downloader.QUICK_RETRY_MS.size, attempts)
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
    fun aRunThatWasCancelledLeavesNothingToTakeAgain() = runTest {
        stopAt = "bb"
        store.requestDownloads(listOf(song("a"), song("bb"), song("c")))
        try {
            downloader.drain(waiting = false)
        } catch (_: CancellationException) {
        }
        store.cancelQueuedDownloads()
        stopAt = null
        assertEquals(mapOf("a" to LibraryStore.DONE), store.downloads().associate { it.track.videoId to it.state })
        assertEquals(0, downloader.drain(waiting = false).done)
        assertEquals(Downloader.Batch.IDLE, downloader.progress.value)
    }

    @Test
    fun anEmptyListIsNothingToDo() = runTest {
        val result = downloader.drain(waiting = false)
        assertEquals(0, result.done)
        assertFalse(result.retryLater)
    }

    @Test
    fun theRunSaysWhichSongIsBeingFetchedAndHowFarItHasGone() = runTest {
        broken += "bb"
        lateinit var seen: Downloader
        val during = mutableListOf<Downloader.Batch>()
        seen = Downloader(store, fetch = { id ->
            during += seen.progress.value
            if (id in broken) throw IOException("no network")
            100L
        })
        store.requestDownloads(listOf(song("a"), song("bb"), song("c")))
        seen.drain(waiting = false)
        assertEquals(
            // The song that fails is asked for again at once, as many times as the quick retries allow, before it counts
            listOf(Downloader.Batch("a", 0, 3, 0)) + List(1 + Downloader.QUICK_RETRY_MS.size) { Downloader.Batch("bb", 1, 3, 0) } +
                Downloader.Batch("c", 1, 3, 1),
            during,
        )
        assertEquals("over: no song is active, the numbers stay", Downloader.Batch(null, 2, 3, 1), seen.progress.value)
    }

    @Test
    fun songsAddedWhileTheRunGoesOnMakeItLonger() = runTest {
        lateinit var seen: Downloader
        val totals = mutableListOf<Int>()
        seen = Downloader(store, fetch = { id ->
            totals += seen.progress.value.total
            if (id == "a") store.requestDownloads(listOf(song("late")))
            100L
        })
        store.requestDownloads(listOf(song("a"), song("b")))
        seen.drain(waiting = false)
        assertEquals(listOf(2, 3, 3), totals)
    }

    @Test
    fun aRunThatWasStoppedAnnouncesNothing() = runTest {
        stopAt = "bb"
        store.requestDownloads(listOf(song("a"), song("bb")))
        try {
            downloader.drain(waiting = false)
        } catch (_: CancellationException) {
        }
        assertEquals(Downloader.Batch.IDLE, downloader.progress.value)
    }

    @Test
    fun aSongFinishedDoesNotSayTheLibraryChanged() = runTest {
        store.requestDownloads(listOf(song("a")))
        var news = 0
        val job = launch(UnconfinedTestDispatcher(testScheduler)) { store.changes.collect { news++ } }
        downloader.drain(waiting = false)
        job.cancel()
        assertEquals(0, news)
    }
}
