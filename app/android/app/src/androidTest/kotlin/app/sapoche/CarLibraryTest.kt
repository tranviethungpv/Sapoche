package app.sapoche

import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.test.core.app.ApplicationProvider
import app.sapoche.sync.QueueItem
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** What a car's screen is offered; the library is the phone's own, in memory. */
class CarLibraryTest {

    private lateinit var store: LibraryStore
    private var queue: List<QueueItem> = emptyList()
    private var vietnamese = false
    private val found = listOf(song("s1"), song("s2"))
    private var rooms = listOf(CarRoom("ABC123", "Road trip", 3), CarRoom("ZZZ999", null, null))
    private val suggestedSongs = listOf(song("m1"), song("m2"), song("m3"))

    private fun song(id: String) = TrackRef(id, "Title $id", "Artist", "https://img/$id", 200_000)

    private fun car() = CarLibrary(store, { queue }, { found }, { vietnamese }, { rooms }, { suggestedSongs })

    @Before
    fun open() {
        store = LibraryStore(ApplicationProvider.getApplicationContext(), name = null)
    }

    @After
    fun close() = store.close()

    @Test
    fun theTopOfTheTreeIsFourTabs() = runTest {
        assertEquals(listOf("now", "rooms", "library", "foryou"), car().children("root")!!.map { it.mediaId })
        assertTrue(car().children("root")!!.all { it.mediaMetadata.isBrowsable == true && it.mediaMetadata.isPlayable == false })
    }

    @Test
    fun theNamesFollowTheLanguageOfTheApp() = runTest {
        vietnamese = true
        assertEquals(listOf("Đang nghe", "Phòng", "Thư viện", "Cho bạn"), car().children("root")!!.map { it.mediaMetadata.title.toString() })
        vietnamese = false
        assertEquals(listOf("Now playing", "Rooms", "Library", "For you"), car().children("root")!!.map { it.mediaMetadata.title.toString() })
    }

    @Test
    fun theLibraryHasLikedRecentAndPlaylists() = runTest {
        assertEquals(listOf("liked", "recent", "playlists"), car().children("library")!!.map { it.mediaId })
    }

    @Test
    fun likedSongsAreSongsOfTheirList() = runTest {
        store.setLiked(song("a"), true, at = 100)
        store.setLiked(song("b"), true, at = 200)
        val items = car().children("liked")!!
        assertEquals(listOf("liked|b", "liked|a"), items.map { it.mediaId })
        assertEquals("Title b", items.first().mediaMetadata.title.toString())
        assertEquals(true, items.first().mediaMetadata.isPlayable)
        assertEquals("https://img/b", items.first().mediaMetadata.artworkUri.toString())
    }

    @Test
    fun aPlaylistIsAFolderWithItsSongsInOrder() = runTest {
        val id = store.createPlaylist("Road", listOf(song("x"), song("y")))
        val folder = car().children("playlists")!!.single()
        assertEquals("pl-$id", folder.mediaId)
        assertEquals("Road", folder.mediaMetadata.title.toString())
        assertEquals(listOf("pl-$id|x", "pl-$id|y"), car().children("pl-$id")!!.map { it.mediaId })
    }

    @Test
    fun theQueueIsWhatIsPlayingNow() = runTest {
        queue = listOf(QueueItem("q1", "v1", "One", "A", null, 1000, addedBy = ""), QueueItem("q2", "v2", "Two", "A", null, 1000, addedBy = ""))
        assertEquals(listOf("now|q1", "now|q2"), car().children("now")!!.map { it.mediaId })
    }

    @Test
    fun aRoomIsPlayableAndSaysHowManyListen() = runTest {
        vietnamese = true
        val items = car().children("rooms")!!
        assertEquals(listOf("room|ABC123", "room|ZZZ999"), items.map { it.mediaId })
        assertTrue(items.all { it.mediaMetadata.isPlayable == true && it.mediaMetadata.isBrowsable == false })
        assertEquals("Road trip", items[0].mediaMetadata.title.toString())
        assertEquals("3 người đang nghe", items[0].mediaMetadata.subtitle.toString())
        // A room with no name is called by its code, and nothing is said of a head count that is not known
        assertEquals("ZZZ999", items[1].mediaMetadata.title.toString())
        assertNull(items[1].mediaMetadata.subtitle)
    }

    @Test
    fun noRoomsIsAnEmptyTab() = runTest {
        rooms = emptyList()
        assertEquals(emptyList<String>(), car().children("rooms")!!.map { it.mediaId })
    }

    @Test
    fun aRoomItemNamesItsCode() = runTest {
        val item = car().item("room|ABC123")!!
        assertEquals("ABC123", CarLibrary.roomCode(item))
        assertNull(CarLibrary.roomCode(car().item("library")!!))
        assertNull(car().item("room|NOPE00"))
    }

    @Test
    fun suggestedSongsPlayFromTheOnePicked() = runTest {
        val car = car()
        assertEquals(listOf("foryou|m1", "foryou|m2", "foryou|m3"), car.children("foryou")!!.map { it.mediaId })
        val (items, at) = car.expand(listOf(MediaItem.Builder().setMediaId("foryou|m2").build()), 0)!!
        assertEquals(3, items.size)
        assertEquals(1, at)
    }

    @Test
    fun aFolderThatIsNotThereIsNotAnswered() = runTest {
        assertNull(car().children("nowhere"))
        assertNull(car().children("pl-abc"))
    }

    @Test
    fun aSongOfAListPlaysTheListFromThere() = runTest {
        store.setLiked(song("a"), true, at = 100)
        store.setLiked(song("b"), true, at = 200)
        store.setLiked(song("c"), true, at = 300)
        val picked = MediaItem.Builder().setMediaId("liked|b").build()
        val (items, at) = car().expand(listOf(picked), startIndex = 0)!!
        assertEquals(listOf("liked|c", "liked|b", "liked|a"), items.map { it.mediaId })
        assertEquals(1, at)
    }

    @Test
    fun aSongOfTheQueueIsLeftAlone() = runTest {
        assertNull(car().expand(listOf(MediaItem.Builder().setMediaId("now|q1").build()), 0))
    }

    @Test
    fun aSpokenRequestIsSearchedFor() = runTest {
        val asked = MediaItem.Builder()
            .setRequestMetadata(androidx.media3.common.MediaItem.RequestMetadata.Builder().setSearchQuery("son tung").build())
            .build()
        val car = car()
        val (items, at) = car.expand(listOf(asked), startIndex = 0)!!
        assertEquals(listOf("found|s1", "found|s2"), items.map { it.mediaId })
        assertEquals(0, at)
        // Playing one of what was found plays the search from there
        val (again, index) = car.expand(listOf(MediaItem.Builder().setMediaId("found|s2").build()), 0)!!
        assertEquals(2, again.size)
        assertEquals(1, index)
    }

    @Test
    fun anItemIsFoundById() = runTest {
        store.setLiked(song("a"), true, at = 100)
        assertNotNull(car().item("liked|a"))
        assertNotNull(car().item("library"))
        assertNull(car().item("liked|zzz"))
    }

    @Test
    fun anItemSaysWhichSongItStandsFor() {
        val item = MediaItem.Builder()
            .setMediaId("liked|abc")
            .setMediaMetadata(MediaMetadata.Builder().setTitle("T").setArtist("A").setDurationMs(5000).build())
            .build()
        assertEquals(TrackRef("abc", "T", "A", null, 5000), CarLibrary.track(item))
    }
}
