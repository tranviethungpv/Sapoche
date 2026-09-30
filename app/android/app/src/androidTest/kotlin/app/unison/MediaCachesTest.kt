package app.unison

import android.content.Context
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.ContentMetadataMutations
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/** The two caches with real files, in folders of their own so the app's are left alone. */
class MediaCachesTest {

    private lateinit var root: File
    private lateinit var caches: MediaCaches

    @Before
    fun open() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        root = File(context.cacheDir, "media-caches-test").also { it.deleteRecursively() }
        caches = MediaCaches(context, playLimitBytes = 1_000, downloadsDir = File(root, "d"), playDir = File(root, "p"))
    }

    @After
    fun close() {
        caches.release()
        root.deleteRecursively()
    }

    /** Puts [length] bytes of a song into [cache], all of it or only the first [written]. */
    private fun keep(cache: Cache, key: String, length: Long, written: Long = length) {
        // The cache wants a claim on the part first, like its own data source makes
        val hole = cache.startReadWrite(key, 0, written)
        val file = cache.startFile(key, 0, written)
        file.writeBytes(ByteArray(written.toInt()) { 1 })
        cache.commitFile(file, written)
        cache.releaseHoleSpan(hole)
        cache.applyContentMetadataMutations(key, ContentMetadataMutations().apply { ContentMetadataMutations.setContentLength(this, length) })
    }

    @Test
    fun nothingIsPinnedUntilSomethingIs() {
        assertNull(caches.pinned("song"))
    }

    @Test
    fun aPinIsFoundInEitherPlaceAndTheDownloadsWin() {
        caches.pin(caches.play, "song", 251)
        assertEquals(251, caches.pinned("song"))
        caches.pin(caches.downloads, "song", 140)
        assertEquals("the downloads are looked at first", 140, caches.pinned("song"))
        assertNull(caches.pinned("other"))
    }

    @Test
    fun aPinWithItsBytesIsKeptWhenTheCacheIsOpenedAgain() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        keep(caches.play, "song", 100)
        caches.pin(caches.play, "song", 251)
        caches.release()
        caches = MediaCaches(context, 1_000, downloadsDir = File(root, "d"), playDir = File(root, "p"))
        assertEquals(251, caches.pinned("song"))
        assertTrue(caches.isComplete("song"))
    }

    @Test
    fun forgettingDropsBytesAndPinInBothPlaces() {
        keep(caches.downloads, "song", 100)
        keep(caches.play, "song", 100)
        caches.pin(caches.downloads, "song", 251)
        caches.pin(caches.play, "song", 251)
        caches.forget("song")
        assertNull(caches.pinned("song"))
        assertFalse(caches.isComplete("song"))
        assertEquals(0L, caches.downloads.cacheSpace)
        assertEquals(0L, caches.play.cacheSpace)
    }

    @Test
    fun aSongIsCompleteOnlyWhenEveryByteIsThere() {
        keep(caches.play, "half", length = 100, written = 40)
        assertFalse(caches.isComplete("half"))
        keep(caches.play, "whole", length = 100)
        assertTrue(caches.isComplete("whole"))
        assertFalse("played, not downloaded", caches.isDownloaded("whole"))
        keep(caches.downloads, "kept", length = 100)
        assertTrue(caches.isDownloaded("kept"))
        assertEquals(100L, caches.downloadedBytes("kept"))
        assertFalse(caches.isComplete("never"))
    }

    @Test
    fun thePlayCacheDropsTheOldestWhenFullButTheDownloadsNever() {
        // The limit is 1000 bytes
        for (i in 1..5) {
            keep(caches.play, "p$i", 300)
            keep(caches.downloads, "d$i", 300)
        }
        assertTrue("the play cache stays within its limit", caches.play.cacheSpace <= 1_000)
        assertFalse("the oldest played song went", caches.isComplete("p1"))
        assertTrue("the newest played song stayed", caches.isComplete("p5"))
        assertEquals(1_500L, caches.downloads.cacheSpace)
        assertTrue(caches.isDownloaded("d1"))
    }

    @Test
    fun clearingEmptiesOnlyTheOneAsked() {
        keep(caches.downloads, "d", 100)
        keep(caches.play, "p", 100)
        caches.clearPlay()
        assertFalse(caches.isComplete("p"))
        assertTrue(caches.isDownloaded("d"))
        caches.clearDownloads()
        assertFalse(caches.isDownloaded("d"))
    }
}
