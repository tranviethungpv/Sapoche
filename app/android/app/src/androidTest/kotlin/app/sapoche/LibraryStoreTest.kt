package app.sapoche

import androidx.test.core.app.ApplicationProvider
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
            // and the tables of the versions after it are there too
            upgraded.putSuggestions("old", listOf(song("s")), at = 9)
            assertEquals(9L, upgraded.cachedSuggestions("old")?.fetchedAt)
        } finally {
            upgraded.close()
            context.deleteDatabase(file)
        }
    }

    // ------------------------------------------------------------------ suggestions

    @Test
    fun everyListenComesBackWithItsOwnTime() = runTest {
        store.recordListen(song("a"), at = 10)
        store.recordListen(song("b"), at = 30)
        store.recordListen(song("a"), at = 20)
        assertEquals(listOf("b" to 30L, "a" to 20L, "a" to 10L), store.listens().map { it.track.videoId to it.at })
    }

    @Test
    fun songsLeftAfterAFewSecondsAreKeptAndForgottenWithTheHistory() = runTest {
        store.recordSkip(song("a"), at = 1)
        store.recordSkip(song("b"), at = 2)
        assertEquals(listOf("b", "a"), store.skipped().map { it.track.videoId })
        // A skipped song is a song something points to, so its details are kept
        assertEquals("Title b", store.skipped().first().track.title)
        store.clearHistory()
        assertEquals(emptyList<String>(), store.skipped().map { it.track.videoId })
    }

    @Test
    fun onlyTheLastSkipsAreKept() = runTest {
        repeat(LibraryStore.SKIPS_KEEP + 20) { store.recordSkip(song("s"), at = it.toLong()) }
        assertEquals(LibraryStore.SKIPS_KEEP, store.skipped().size)
        assertEquals((LibraryStore.SKIPS_KEEP + 19).toLong(), store.skipped().first().at)
    }

    @Test
    fun blockedSongsAndArtistsAreListedAndCanBeLetBack() = runTest {
        store.block("song", "x", "Song X", at = 1)
        store.block("artist", "some artist", "Some Artist", at = 2)
        store.block("song", "x", "Song X renamed", at = 3)
        assertEquals(
            listOf(LibraryStore.Blocked("song", "x", "Song X renamed"), LibraryStore.Blocked("artist", "some artist", "Some Artist")),
            store.blocked(),
        )
        store.unblock("song", "x")
        assertEquals(listOf("artist"), store.blocked().map { it.kind })
    }

    @Test
    fun aDatabaseFromVersionFourGainsSkipsAndBlocked() = runTest {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val file = "upgrade-test4.db"
        context.deleteDatabase(file)
        context.openOrCreateDatabase(file, android.content.Context.MODE_PRIVATE, null).use { db ->
            db.execSQL("CREATE TABLE tracks(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, thumb TEXT, dur_ms INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE likes(video_id TEXT PRIMARY KEY REFERENCES tracks(video_id), liked_at INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, video_id TEXT NOT NULL REFERENCES tracks(video_id), played_at INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE playlist_items(playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE, video_id TEXT NOT NULL REFERENCES tracks(video_id), position INTEGER NOT NULL, PRIMARY KEY(playlist_id, video_id))")
            db.execSQL("CREATE TABLE suggestions(seed_video_id TEXT PRIMARY KEY, json TEXT NOT NULL, fetched_at INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE downloads(video_id TEXT PRIMARY KEY REFERENCES tracks(video_id), state TEXT NOT NULL, bytes INTEGER NOT NULL DEFAULT 0, tries INTEGER NOT NULL DEFAULT 0, at INTEGER NOT NULL)")
            db.execSQL("INSERT INTO tracks VALUES('old', 'Old song', 'Old artist', NULL, 1000)")
            db.execSQL("INSERT INTO history(video_id, played_at) VALUES('old', 5)")
            db.version = 4
        }
        val upgraded = LibraryStore(context, file)
        try {
            assertEquals(listOf("old"), upgraded.listens().map { it.track.videoId })
            upgraded.recordSkip(song("new"), at = 7)
            upgraded.block("artist", "x", "X")
            assertEquals(listOf("new"), upgraded.skipped().map { it.track.videoId })
            assertEquals(1, upgraded.blocked().size)
        } finally {
            upgraded.close()
            context.deleteDatabase(file)
        }
    }

    @Test
    fun whatWasFetchedForASeedComesBackWithItsTime() = runTest {
        assertNull(store.cachedSuggestions("seed"))
        store.putSuggestions("seed", listOf(song("a"), song("b").copy(thumb = null, title = "Quote \" and, comma")), at = 42)
        val kept = store.cachedSuggestions("seed")!!
        assertEquals(42L, kept.fetchedAt)
        assertEquals(listOf("a", "b"), kept.tracks.map { it.videoId })
        assertEquals(song("a"), kept.tracks[0])
        assertEquals(song("b").copy(thumb = null, title = "Quote \" and, comma"), kept.tracks[1])
    }

    @Test
    fun fetchingAgainReplacesTheOldList() = runTest {
        store.putSuggestions("seed", listOf(song("a")), at = 1)
        store.putSuggestions("seed", listOf(song("b")), at = 2)
        assertEquals(listOf("b"), store.cachedSuggestions("seed")!!.tracks.map { it.videoId })
    }

    @Test
    fun suggestionsOfSeedsThatAreGoneAreForgotten() = runTest {
        store.putSuggestions("a", listOf(song("x")), at = 1)
        store.putSuggestions("b", listOf(song("y")), at = 1)
        store.keepSuggestionsFor(listOf("b"))
        assertNull(store.cachedSuggestions("a"))
        assertEquals(1, store.cachedSuggestions("b")!!.tracks.size)
        store.keepSuggestionsFor(emptyList())
        assertNull(store.cachedSuggestions("b"))
    }

    @Test
    fun heardAndLikedSongsCanBeListed() = runTest {
        store.recordListen(song("old"), at = 10)
        store.recordListen(song("new"), at = 100)
        store.setLiked(song("liked"), true, at = 5)
        assertEquals(setOf("new"), store.heardSince(50))
        assertEquals(setOf("old", "new"), store.heardSince(0))
        assertEquals(setOf("liked"), store.likedIds())
    }

    @Test
    fun suggestionsDoNotKeepASongAliveInTheLibrary() = runTest {
        store.recordListen(song("a"), at = 1)
        store.putSuggestions("a", listOf(song("x")), at = 1)
        store.clearHistory()
        // The suggestion list is its own thing: it stays, and the heard song is gone
        assertEquals(emptyList<String>(), store.recent().map { it.track.videoId })
        assertEquals(1, store.cachedSuggestions("a")!!.tracks.size)
    }

    // ------------------------------------------------------------------ downloads

    private suspend fun states() = store.downloads().associate { it.track.videoId to it.state }

    @Test
    fun requestedSongsAreQueuedInOrderAndDoneOnesComeFirst() = runTest {
        store.requestDownloads(listOf(song("a"), song("b"), song("c")), at = 1)
        assertEquals("a", store.nextDownload(LibraryStore.QUEUED))
        store.finishDownload("b", 1234, at = 10)
        store.finishDownload("a", 99, at = 20)
        val list = store.downloads()
        assertEquals("done ones newest first, then the waiting", listOf("a", "b", "c"), list.map { it.track.videoId })
        assertEquals(listOf(LibraryStore.DONE, LibraryStore.DONE, LibraryStore.QUEUED), list.map { it.state })
        assertEquals(99L, list[0].bytes)
        assertEquals("c", store.nextDownload(LibraryStore.QUEUED))
        assertNull(store.nextDownload(LibraryStore.WAITING))
    }

    @Test
    fun asongAlreadyDoneStaysDoneWhenAskedAgain() = runTest {
        store.requestDownloads(listOf(song("a")))
        store.finishDownload("a", 10)
        store.requestDownloads(listOf(song("a")))
        assertEquals(mapOf("a" to LibraryStore.DONE), states())
    }

    @Test
    fun askingForAWaitingSongThePlainWayStartsItNow() = runTest {
        store.requestDownloads(listOf(song("a")), waiting = true)
        assertEquals("a", store.nextDownload(LibraryStore.WAITING))
        assertNull(store.nextDownload(LibraryStore.QUEUED))
        store.requestDownloads(listOf(song("a")))
        assertEquals("a", store.nextDownload(LibraryStore.QUEUED))
        assertNull(store.nextDownload(LibraryStore.WAITING))
    }

    @Test
    fun waitingNeverPutsAQueuedSongBackToWaiting() = runTest {
        store.requestDownloads(listOf(song("a")))
        store.requestDownloads(listOf(song("a")), waiting = true)
        assertEquals("a", store.nextDownload(LibraryStore.QUEUED))
    }

    @Test
    fun aSongFailsForGoodAfterThreeTriesAndAskingAgainRevivesIt() = runTest {
        store.requestDownloads(listOf(song("a")))
        assertFalse(store.failDownload("a"))
        assertFalse(store.failDownload("a"))
        assertEquals(mapOf("a" to LibraryStore.QUEUED), states())
        assertTrue(store.failDownload("a"))
        assertEquals(mapOf("a" to LibraryStore.FAILED), states())
        assertNull(store.nextDownload(LibraryStore.QUEUED))
        store.requestDownloads(listOf(song("a")))
        assertEquals(mapOf("a" to LibraryStore.QUEUED), states())
        assertFalse("the count started again", store.failDownload("a"))
    }

    @Test
    fun skippedSongsAreLeftOutOfTheNextPick() = runTest {
        store.requestDownloads(listOf(song("a"), song("b")))
        assertEquals("b", store.nextDownload(LibraryStore.QUEUED, skip = setOf("a")))
        assertNull(store.nextDownload(LibraryStore.QUEUED, skip = setOf("a", "b")))
    }

    @Test
    fun removingDownloadsForgetsSongsNothingElsePointsTo() = runTest {
        store.setLiked(song("a"), true, at = 1)
        store.requestDownloads(listOf(song("a"), song("b")))
        store.removeDownload("a")
        store.removeDownload("b")
        assertEquals(emptyList<String>(), store.downloads().map { it.track.videoId })
        assertEquals("Title a", store.liked().single().track.title)
        store.requestDownloads(listOf(song("c")))
        store.clearDownloads()
        assertEquals(emptyList<String>(), store.downloads().map { it.track.videoId })
    }

    @Test
    fun aDownloadedSongSurvivesEverythingElseLettingGo() = runTest {
        store.requestDownloads(listOf(song("a")))
        store.recordListen(song("a"), at = 1)
        store.setLiked(song("a"), true, at = 2)
        store.clearHistory()
        store.setLiked(song("a"), false)
        assertEquals("Title a", store.downloads().single().track.title)
    }

    @Test
    fun likedSongsNotOnTheListYetAreTheOnesToDownloadByThemselves() = runTest {
        store.setLiked(song("a"), true, at = 1)
        store.setLiked(song("b"), true, at = 2)
        store.setLiked(song("c"), true, at = 3)
        store.requestDownloads(listOf(song("a")))
        store.finishDownload("a", 1)
        store.requestDownloads(listOf(song("c")))
        store.failDownload("c")
        store.failDownload("c")
        store.failDownload("c")
        assertEquals("done and failed ones are not asked again", listOf("b"), store.likedToDownload().map { it.videoId })
    }

    @Test
    fun aDatabaseFromVersionThreeGainsDownloads() = runTest {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val file = "upgrade-test3.db"
        context.deleteDatabase(file)
        context.openOrCreateDatabase(file, android.content.Context.MODE_PRIVATE, null).use { db ->
            db.execSQL("CREATE TABLE tracks(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, thumb TEXT, dur_ms INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE likes(video_id TEXT PRIMARY KEY REFERENCES tracks(video_id), liked_at INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, video_id TEXT NOT NULL REFERENCES tracks(video_id), played_at INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE playlist_items(playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE, video_id TEXT NOT NULL REFERENCES tracks(video_id), position INTEGER NOT NULL, PRIMARY KEY(playlist_id, video_id))")
            db.execSQL("CREATE TABLE suggestions(seed_video_id TEXT PRIMARY KEY, json TEXT NOT NULL, fetched_at INTEGER NOT NULL)")
            db.execSQL("INSERT INTO tracks VALUES('old', 'Old song', 'Old artist', NULL, 1000)")
            db.execSQL("INSERT INTO likes VALUES('old', 5)")
            db.execSQL("INSERT INTO playlists(name, created_at, updated_at) VALUES('Mix', 1, 1)")
            db.execSQL("INSERT INTO playlist_items VALUES(1, 'old', 0)")
            db.version = 3
        }
        val upgraded = LibraryStore(context, file)
        try {
            assertEquals("Old song", upgraded.liked().single().track.title)
            assertEquals(1, upgraded.playlists().single().count)
            upgraded.requestDownloads(listOf(song("new")))
            assertEquals(listOf("new"), upgraded.downloads().map { it.track.videoId })
        } finally {
            upgraded.close()
            context.deleteDatabase(file)
        }
    }
}
