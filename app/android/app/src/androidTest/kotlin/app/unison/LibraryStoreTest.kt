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

    // ------------------------------------------------------------------ playlists

    private suspend fun ids(id: Long) = store.playlistTracks(id).map { it.videoId }

    @Test
    fun aPlaylistKeepsItsSongsInTheOrderGiven() = runTest {
        val id = store.createPlaylist("Road trip", listOf(song("c"), song("a"), song("b")))
        assertEquals(listOf("c", "a", "b"), ids(id))
        assertEquals(song("a"), store.playlistTracks(id)[1])
    }

    @Test
    fun theListShowsNameCountAndTheFirstCover() = runTest {
        val id = store.createPlaylist("Road trip", listOf(song("c"), song("a")), at = 10)
        store.createPlaylist("Empty", at = 20)
        val lists = store.playlists()
        assertEquals("the one changed last first", listOf("Empty", "Road trip"), lists.map { it.name })
        val trip = lists.single { it.id == id }
        assertEquals(2, trip.count)
        assertEquals("https://img/c", trip.thumb)
        assertEquals(0, lists.first().count)
        assertEquals(null, lists.first().thumb)
    }

    @Test
    fun addingKeepsWhatIsThereAndSkipsRepeats() = runTest {
        val id = store.createPlaylist("Mix", listOf(song("a"), song("b")))
        assertEquals(2, store.addToPlaylist(id, listOf(song("b"), song("c"), song("d"))))
        assertEquals(listOf("a", "b", "c", "d"), ids(id))
    }

    @Test
    fun removingASongClosesTheGap() = runTest {
        val id = store.createPlaylist("Mix", listOf(song("a"), song("b"), song("c")))
        store.removeFromPlaylist(id, "b")
        assertEquals(listOf("a", "c"), ids(id))
        store.addToPlaylist(id, listOf(song("d")))
        assertEquals(listOf("a", "c", "d"), ids(id))
    }

    @Test
    fun aSongCanBeMovedUpAndDown() = runTest {
        val id = store.createPlaylist("Mix", listOf(song("a"), song("b"), song("c"), song("d")))
        store.movePlaylistItem(id, "d", 0)
        assertEquals(listOf("d", "a", "b", "c"), ids(id))
        store.movePlaylistItem(id, "d", 2)
        assertEquals(listOf("a", "b", "d", "c"), ids(id))
        store.movePlaylistItem(id, "a", 99)
        assertEquals("past the end means last", listOf("b", "d", "c", "a"), ids(id))
        store.movePlaylistItem(id, "zzz", 0)
        assertEquals("a song that is not there changes nothing", listOf("b", "d", "c", "a"), ids(id))
    }

    @Test
    fun renamingTrimsAndNeverLeavesAnEmptyName() = runTest {
        val id = store.createPlaylist("  Old  ")
        assertEquals("Old", store.playlists().single().name)
        store.renamePlaylist(id, "  New name ")
        assertEquals("New name", store.playlists().single().name)
        store.renamePlaylist(id, "   ")
        assertEquals("Untitled", store.playlists().single().name)
        store.renamePlaylist(id, "x".repeat(200))
        assertEquals(LibraryStore.MAX_NAME, store.playlists().single().name.length)
    }

    @Test
    fun deletingAPlaylistKeepsSongsUsedElsewhereAndForgetsTheRest() = runTest {
        store.setLiked(song("a"), true, at = 1)
        val id = store.createPlaylist("Mix", listOf(song("a"), song("b")))
        store.deletePlaylist(id)
        assertEquals(emptyList<String>(), store.playlists().map { it.name })
        assertEquals(emptyList<String>(), ids(id))
        assertEquals("Title a", store.liked().single().track.title)
        // b was only in the playlist, so it is gone and can be added again
        val again = store.createPlaylist("Again", listOf(song("b")))
        assertEquals(listOf("b"), ids(again))
    }

    @Test
    fun aSongInAPlaylistSurvivesClearingHistoryAndUnliking() = runTest {
        val id = store.createPlaylist("Mix", listOf(song("a")))
        store.recordListen(song("a"), at = 1)
        store.setLiked(song("a"), true, at = 2)
        store.clearHistory()
        store.setLiked(song("a"), false)
        assertEquals("Title a", store.playlistTracks(id).single().title)
    }

    @Test
    fun aPlaylistHoldsAtMostFiveHundredSongs() = runTest {
        val id = store.createPlaylist("Big", (1..LibraryStore.MAX_PLAYLIST + 20).map { song("s$it") })
        assertEquals(LibraryStore.MAX_PLAYLIST, store.playlistTracks(id).size)
        assertEquals(0, store.addToPlaylist(id, listOf(song("more"))))
        // Room comes back when a song is taken out
        store.removeFromPlaylist(id, "s1")
        assertEquals(1, store.addToPlaylist(id, listOf(song("more"))))
        assertEquals("more", ids(id).last())
    }

    @Test
    fun changingAPlaylistBringsItToTheTop() = runTest {
        val first = store.createPlaylist("First", at = 10)
        store.createPlaylist("Second", at = 20)
        store.addToPlaylist(first, listOf(song("a")), at = 30)
        assertEquals(listOf("First", "Second"), store.playlists().map { it.name })
    }

    @Test
    fun aDatabaseFromTheFirstVersionGainsPlaylistsAndKeepsItsData() = runTest {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val file = "upgrade-test.db"
        context.deleteDatabase(file)
        // The tables exactly as version 1 created them
        context.openOrCreateDatabase(file, android.content.Context.MODE_PRIVATE, null).use { db ->
            db.execSQL("CREATE TABLE tracks(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, thumb TEXT, dur_ms INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE likes(video_id TEXT PRIMARY KEY REFERENCES tracks(video_id), liked_at INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, video_id TEXT NOT NULL REFERENCES tracks(video_id), played_at INTEGER NOT NULL)")
            db.execSQL("INSERT INTO tracks VALUES('old', 'Old song', 'Old artist', NULL, 1000)")
            db.execSQL("INSERT INTO likes VALUES('old', 5)")
            db.execSQL("INSERT INTO history(video_id, played_at) VALUES('old', 6)")
            db.version = 1
        }
        val upgraded = LibraryStore(context, file)
        try {
            assertEquals("Old song", upgraded.liked().single().track.title)
            assertEquals(1, upgraded.recent().single().plays)
            val id = upgraded.createPlaylist("New", listOf(song("a")))
            assertEquals(listOf("a"), upgraded.playlistTracks(id).map { it.videoId })
            // The old song is still pointed to by its like and its history, so it is kept
            upgraded.deletePlaylist(id)
            assertEquals("Old song", upgraded.liked().single().track.title)
        } finally {
            upgraded.close()
            context.deleteDatabase(file)
        }
    }
}
