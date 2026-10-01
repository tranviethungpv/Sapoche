package app.unison.core

import kotlinx.coroutines.test.runTest
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MusicFeedTest {

    private val dir: File = createTempDirectory("lyrics").toFile()

    @AfterTest
    fun cleanUp() {
        dir.deleteRecursively()
    }

    private class FakeMusic : MusicSource {
        var nextCalls = 0
        var lyricsCalls = 0
        var plain: String? = "plain from youtube"
        var lyricsId: String? = "MPLY"

        override suspend fun watchNext(videoId: String, radio: Boolean): WatchNext {
            nextCalls++
            return WatchNext(listOf(MusicTrack(videoId, "T", "A")), lyricsId, "MPTR")
        }

        override suspend fun related(relatedId: String) = Related(emptyList(), emptyList(), emptyList(), emptyList(), null)
        override suspend fun lyrics(lyricsId: String): String? = plain.also { lyricsCalls++ }
        override suspend fun artist(artistId: String) = ArtistPage(artistId, "N", null, null, null, emptyList(), emptyList(), emptyList(), emptyList())
        override suspend fun searchSongs(query: String) = emptyList<MusicTrack>()
        override suspend fun searchVideos(query: String) = emptyList<MusicTrack>()
        override suspend fun trending(language: String) = emptyList<MusicShelf>()
    }

    private class FakeLrclib(var body: String?) : LyricsFetch {
        var asked = 0
        override suspend fun get(url: String): String? {
            asked++
            return body
        }
    }

    private val synced = """{"duration":214.0,"plainLyrics":"One","syncedLyrics":"[00:01.00] One"}"""

    private fun feed(music: FakeMusic, lrclib: FakeLrclib, clock: () -> Long = { 0L }) =
        MusicFeed(music, LyricsClient(lrclib), LyricsStore(dir), clock)

    @Test
    fun `lyrics with times from LRCLIB win over the plain words of YouTube`() = runTest {
        val music = FakeMusic()
        val lyrics = feed(music, FakeLrclib(synced)).lyrics("id1", "T", "A", 214)!!
        assertTrue(lyrics.synced)
        assertEquals(0, music.lyricsCalls)
    }

    @Test
    fun `when LRCLIB has nothing the plain words of YouTube are used`() = runTest {
        val lyrics = feed(FakeMusic(), FakeLrclib(null)).lyrics("id1", "T", "A", 214)!!
        assertFalse(lyrics.synced)
        assertEquals("plain from youtube", lyrics.plain)
    }

    @Test
    fun `plain words from LRCLIB are the last resort`() = runTest {
        val music = FakeMusic().apply { plain = null }
        val lyrics = feed(music, FakeLrclib("""{"duration":214.0,"plainLyrics":"Words","syncedLyrics":null}""")).lyrics("id1", "T", "A", 214)!!
        assertEquals("Words", lyrics.plain)
    }

    @Test
    fun `a song looked up once is not asked for again`() = runTest {
        val music = FakeMusic()
        val lrclib = FakeLrclib(synced)
        val feed = feed(music, lrclib)
        feed.lyrics("id1", "T", "A", 214)
        val asked = lrclib.asked
        assertEquals("One", feed.lyrics("id1", "T", "A", 214)!!.lines.single().text)
        assertEquals(asked, lrclib.asked)
        // Nor after a restart: a new feed on the same files
        val later = feed(music, lrclib)
        later.lyrics("id1", "T", "A", 214)
        assertEquals(asked, lrclib.asked)
    }

    @Test
    fun `a song without lyrics is asked about again only after a week`() = runTest {
        var time = 1_000L
        val music = FakeMusic().apply { lyricsId = null }
        val lrclib = FakeLrclib(null)
        val feed = feed(music, lrclib) { time }
        assertNull(feed.lyrics("id1", "T", "A", 214))
        val asked = lrclib.asked
        time += 60_000
        assertNull(feed.lyrics("id1", "T", "A", 214))
        assertEquals(asked, lrclib.asked, "a minute later nothing is asked")

        time += MusicFeed.MISSING_MS
        lrclib.body = synced
        assertTrue(feed.lyrics("id1", "T", "A", 214)!!.synced)
    }

    @Test
    fun `the radio of a song is asked for once while it is fresh`() = runTest {
        val music = FakeMusic()
        val feed = feed(music, FakeLrclib(null))
        feed.watchNext("id1")
        feed.watchNext("id1")
        feed.related("id1")
        assertEquals(1, music.nextCalls)
        feed.watchNext("id2")
        assertEquals(2, music.nextCalls)
    }

    @Test
    fun `what is trending is asked for once for hours`() = runTest {
        var time = 0L
        var asked = 0
        val music = object : MusicSource by FakeMusic() {
            override suspend fun trending(language: String): List<MusicShelf> {
                asked++
                return listOf(MusicShelf("Hits", listOf(MusicTrack("a", "T", "A"))))
            }
        }
        val feed = MusicFeed(music, LyricsClient(FakeLrclib(null)), LyricsStore(dir)) { time }
        assertEquals("Hits", feed.trending().single().title)
        time += MusicFeed.TRENDING_MS - 1
        feed.trending()
        assertEquals(1, asked)
        time += 1
        feed.trending()
        assertEquals(2, asked)
    }

    @Test
    fun `trending is asked again when the language changes, and not shown in the wrong one`() = runTest {
        val asked = mutableListOf<String>()
        val music = object : MusicSource by FakeMusic() {
            override suspend fun trending(language: String): List<MusicShelf> {
                asked += language
                return listOf(MusicShelf("Hits in $language", listOf(MusicTrack("a", "T", "A"))))
            }
        }
        val feed = MusicFeed(music, LyricsClient(FakeLrclib(null)), LyricsStore(dir)) { 0L }
        assertEquals("Hits in en", feed.trending("en").single().title)
        assertEquals("Hits in vi", feed.trending("vi").single().title)
        assertEquals("Hits in vi", feed.trending("vi").single().title)
        assertEquals(listOf("en", "vi"), asked)
    }

    @Test
    fun `a search asks for songs or for videos`() = runTest {
        val music = object : MusicSource by FakeMusic() {
            override suspend fun searchSongs(query: String) = listOf(MusicTrack("song", "T", "A", isSong = true))
            override suspend fun searchVideos(query: String) = listOf(MusicTrack("clip", "T", "A"))
        }
        val feed = MusicFeed(music, LyricsClient(FakeLrclib(null)), LyricsStore(dir))
        assertEquals("song", feed.search("q", songs = true).single().videoId)
        assertEquals("clip", feed.search("q", songs = false).single().videoId)
    }

    @Test
    fun `a song with no related page gives none`() = runTest {
        val music = object : MusicSource by FakeMusic() {
            override suspend fun watchNext(videoId: String, radio: Boolean) = WatchNext(emptyList(), null, null)
        }
        assertNull(MusicFeed(music, LyricsClient(FakeLrclib(null)), LyricsStore(dir)).related("id1"))
    }

    @Test
    fun `the store keeps only the newest files and survives a damaged one`() {
        val store = LyricsStore(dir, maxEntries = 2)
        store.putFound("a", Lyrics(emptyList(), "x"))
        store.putFound("b", Lyrics(emptyList(), "x"))
        File(dir, "a.json").setLastModified(1_000)
        store.putFound("c", Lyrics(emptyList(), "x"))
        assertNull(store.get("a"))
        assertTrue(store.get("b") is KeptLyrics.Found)

        File(dir, "b.json").writeText("{ cut off")
        assertNull(store.get("b"))
        assertFalse(File(dir, "b.json").exists())
    }

    @Test
    fun `a name from outside cannot point out of the folder`() {
        val store = LyricsStore(dir)
        store.putFound("../../evil", Lyrics(emptyList(), "x"))
        assertTrue(dir.listFiles()!!.all { it.parentFile == dir })
        assertTrue(store.get("../../evil") is KeptLyrics.Found)
    }
}
