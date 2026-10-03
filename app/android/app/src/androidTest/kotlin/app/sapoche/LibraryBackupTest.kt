package app.sapoche

import androidx.test.core.app.ApplicationProvider
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Runs on a phone: a library is written to a file and read back into another, empty one. */
class LibraryBackupTest {

    private lateinit var from: LibraryStore
    private lateinit var to: LibraryStore

    private fun song(id: String) = TrackRef(id, "Title $id", "Artist $id", "https://img/$id", 200_000)

    @Before
    fun open() {
        from = LibraryStore(ApplicationProvider.getApplicationContext(), name = null)
        to = LibraryStore(ApplicationProvider.getApplicationContext(), name = null)
    }

    @After
    fun close() {
        from.close()
        to.close()
    }

    private suspend fun fill() {
        from.setLiked(song("a"), true, at = 100)
        from.setLiked(song("b"), true, at = 200)
        from.createPlaylist("Road trip", listOf(song("c"), song("a"), song("d")), at = 50)
        from.createPlaylist("Empty", emptyList(), at = 60)
        from.recordListen(song("a"), at = 10)
        from.recordListen(song("e"), at = 20)
        from.recordListen(song("a"), at = 30)
    }

    /** What a person sees of a library, to compare two of them. */
    private suspend fun view(store: LibraryStore) = listOf(
        store.liked().map { it.track to it.at },
        store.playlists().sortedBy { it.name }.map { it.name to store.playlistTracks(it.id) },
        store.recent().map { Triple(it.track, it.at, it.plays) },
    )

    @Test
    fun aLibraryWrittenAndReadBackIsTheSame() = runTest {
        fill()
        val text = LibraryBackup.toJson(from.backup(), at = 1234)
        val restored = to.restore(LibraryBackup.fromJson(text))
        assertEquals(LibraryStore.Restored(liked = 2, playlists = 2, listens = 3), restored)
        assertEquals(view(from), view(to))
        assertEquals(listOf("c", "a", "d"), to.playlistTracks(to.playlists().first { it.name == "Road trip" }.id).map { it.videoId })
    }

    @Test
    fun restoringAgainChangesNothing() = runTest {
        fill()
        val backup = LibraryBackup.fromJson(LibraryBackup.toJson(from.backup(), at = 1))
        to.restore(backup)
        val before = view(to)
        assertEquals(LibraryStore.Restored(0, 0, 0), to.restore(backup))
        assertEquals(before, view(to))
    }

    @Test
    fun restoringOnThePhoneItCameFromChangesNothing() = runTest {
        fill()
        assertEquals(LibraryStore.Restored(0, 0, 0), from.restore(from.backup()))
        assertEquals(2, from.playlists().size)
    }

    @Test
    fun whatIsHereIsKeptAndWhatIsNewIsAdded() = runTest {
        fill()
        to.setLiked(song("a"), true, at = 999) // liked here at another time: that time stays
        to.setLiked(song("z"), true, at = 5)
        to.createPlaylist("Road trip", listOf(song("d"), song("y")), at = 1)
        val restored = to.restore(from.backup())

        assertEquals(LibraryStore.Restored(liked = 1, playlists = 2, listens = 3), restored)
        assertEquals(listOf("z" to 5L, "a" to 999L, "b" to 200L).sortedBy { it.first }, to.liked().map { it.track.videoId to it.at }.sortedBy { it.first })
        val trip = to.playlists().first { it.name == "Road trip" }
        // The songs already there stay first; only the missing ones follow
        assertEquals(listOf("d", "y", "c", "a"), to.playlistTracks(trip.id).map { it.videoId })
        assertEquals(2, to.playlists().count { it.name == "Road trip" || it.name == "Empty" })
    }

    @Test
    fun listensOverTheLimitLoseTheOldestByTime() = runTest {
        for (i in 1..LibraryStore.HISTORY_KEEP) to.recordListen(song("new"), at = 1_000_000L + i)
        val backup = LibraryStore.Backup(emptyList(), emptyList(), listOf(LibraryStore.Entry(song("old"), 5)))
        assertEquals(1, to.restore(backup).listens)
        // The old listen arrived last but is the oldest, so it is the one to go, and with it its song
        assertEquals(listOf("new"), to.recent().map { it.track.videoId })
    }

    @Test
    fun aSongIsWrittenOnceHoweverOftenItIsUsed() = runTest {
        fill()
        val text = LibraryBackup.toJson(from.backup(), at = 1)
        assertEquals(1, Regex("\"Title a\"").findAll(text).count())
    }

    @Test
    fun otherFilesAreRefused() {
        assertThrows(LibraryBackup.FormatException::class.java) { LibraryBackup.fromJson("hello") }
        assertThrows(LibraryBackup.FormatException::class.java) { LibraryBackup.fromJson("{\"a\":1}") }
        assertThrows(LibraryBackup.FormatException::class.java) {
            LibraryBackup.fromJson("{\"app\":\"sapoche\",\"version\":99,\"songs\":{}}")
        }
    }

    @Test
    fun aBackupMadeUnderTheFormerNameIsStillRead() {
        val backup = LibraryBackup.fromJson("""{"app":"unison","version":1,"songs":{"a":{"title":"A","artist":"x","thumb":null,"durMs":5}},"liked":[{"id":"a","at":7}]}""")
        assertEquals(listOf("a"), backup.liked.map { it.track.videoId })
    }

    @Test
    fun brokenEntriesAreLeftOutAndTheRestIsKept() = runTest {
        val text = """{"app":"sapoche","version":1,"songs":{"a":{"title":"A","artist":"x","thumb":null,"durMs":5},"":{"title":"no id"},"b":{"title":""}},
            "liked":[{"id":"a","at":7},{"id":"missing","at":8},{"id":"b","at":9}],
            "playlists":[{"name":"P","songs":["a","nope"]}],"history":[]}""".trimIndent()
        val backup = LibraryBackup.fromJson(text)
        assertEquals(listOf("a"), backup.liked.map { it.track.videoId })
        assertEquals(null, backup.liked.single().track.thumb)
        assertEquals(listOf("a"), backup.playlists.single().tracks.map { it.videoId })
        to.restore(backup)
        assertTrue(to.liked().isNotEmpty())
    }
}
