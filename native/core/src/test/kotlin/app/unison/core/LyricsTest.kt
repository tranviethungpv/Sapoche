package app.unison.core

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LyricsTest {

    @Test
    fun `lines are read with their times in order`() {
        val lines = Lrc.parse("[ar:Someone]\n[00:12.50] Second\n[00:01.00]First\n[01:02.05]Third")
        assertEquals(listOf(LyricLine(1000, "First"), LyricLine(12_500, "Second"), LyricLine(62_050, "Third")), lines)
    }

    @Test
    fun `a line with several times is sung each time`() {
        val lines = Lrc.parse("[00:10.00][00:30.00]Chorus")
        assertEquals(listOf(LyricLine(10_000, "Chorus"), LyricLine(30_000, "Chorus")), lines)
    }

    @Test
    fun `an empty line is kept as a pause and fractions are read as they are`() {
        assertEquals(listOf(LyricLine(5500, ""), LyricLine(6010, "x")), Lrc.parse("[00:05.5]\n[00:06.01]x"))
    }

    @Test
    fun `text that is not lyrics with times gives no lines`() {
        assertEquals(emptyList(), Lrc.parse("Just words\nmore words"))
    }

    private class FakeLrclib(private val answers: Map<String, String>) : LyricsFetch {
        val asked = mutableListOf<String>()
        override suspend fun get(url: String): String? {
            asked += url
            return answers.entries.firstOrNull { url.contains(it.key) }?.value
        }
    }

    private val synced = """{"duration":213.0,"instrumental":false,"plainLyrics":"One\nTwo","syncedLyrics":"[00:01.00] One\n[00:02.00] Two"}"""

    @Test
    fun `an exact match gives the lyrics with times`() = runTest {
        val lyrics = LyricsClient(FakeLrclib(mapOf("api/get" to synced))).find("Song", "Artist", 214)!!
        assertTrue(lyrics.synced)
        assertEquals(listOf("One", "Two"), lyrics.lines.map { it.text })
        assertEquals("One\nTwo", lyrics.plain)
    }

    @Test
    fun `the service is told the name and the length and nothing else`() = runTest {
        val fetch = FakeLrclib(mapOf("api/get" to synced))
        LyricsClient(fetch).find("Song", "Artist", 214)
        assertEquals("https://lrclib.net/api/get?track_name=Song&artist_name=Artist&duration=214", fetch.asked.single())
    }

    @Test
    fun `when the name with tags is not known the name without them is tried`() = runTest {
        val fetch = FakeLrclib(mapOf("track_name=Song&artist_name=Artist&" to synced))
        val lyrics = LyricsClient(fetch).find("Song (Official Video)", "Artist - Topic", 214)
        assertTrue(lyrics!!.synced)
        assertEquals(2, fetch.asked.size)
    }

    @Test
    fun `without an exact match the nearest length with lines wins`() = runTest {
        val search = """[
            {"duration":300.0,"plainLyrics":"far","syncedLyrics":"[00:01.00] far"},
            {"duration":212.0,"plainLyrics":"plain only","syncedLyrics":null},
            {"duration":215.0,"plainLyrics":"near","syncedLyrics":"[00:01.00] near"}
        ]"""
        val lyrics = LyricsClient(FakeLrclib(mapOf("api/search" to search))).find("Song", "Artist", 214)!!
        assertEquals("near", lyrics.lines.single().text)
    }

    @Test
    fun `lyrics of a much longer recording are not used`() = runTest {
        val search = """[{"duration":400.0,"plainLyrics":"other","syncedLyrics":"[00:01.00] other"}]"""
        assertNull(LyricsClient(FakeLrclib(mapOf("api/search" to search))).find("Song", "Artist", 214))
    }

    @Test
    fun `an instrumental and a song nobody wrote down give nothing`() = runTest {
        val instrumental = """{"duration":214.0,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"""
        assertNull(LyricsClient(FakeLrclib(mapOf("api/get" to instrumental))).find("Song", "Artist", 214))
        assertNull(LyricsClient(FakeLrclib(emptyMap())).find("Song", "Artist", 214))
    }

    @Test
    fun `plain words are kept when there are no times`() = runTest {
        val plain = """{"duration":214.0,"plainLyrics":"Only words","syncedLyrics":null}"""
        val lyrics = LyricsClient(FakeLrclib(mapOf("api/get" to plain))).find("Song", "Artist", 214)!!
        assertFalse(lyrics.synced)
        assertEquals("Only words", lyrics.plain)
    }

    @Test
    fun `tags that only describe the recording are taken off the title`() {
        assertEquals("Never Gonna Give You Up", SongNames.title("Never Gonna Give You Up (Official Video)"))
        assertEquals("Take On Me", SongNames.title("Take On Me [Official Music Video] [HD]"))
        assertEquals("Song", SongNames.title("Song (feat. Someone)"))
        assertEquals("Song", SongNames.title("Song (2009 Remaster)"))
        assertEquals("Song (Remix)", SongNames.title("Song (Remix)"), "a remix is another recording")
        assertEquals("Song (Live)", SongNames.title("Song (Live)"))
        assertEquals("(Official)", SongNames.title("(Official)"), "never leaves nothing")
    }

    @Test
    fun `a leading artist name is dropped from the title`() {
        assertEquals("Hello", SongNames.title("Adele - Hello", artist = "Adele"))
        assertEquals("A - B", SongNames.title("A - B", artist = "Someone else"))
    }

    @Test
    fun `the first artist is the main one`() {
        assertEquals("Sơn Tùng M-TP", SongNames.artist("Sơn Tùng M-TP"))
        assertEquals("Rick Astley", SongNames.artist("Rick Astley - Topic"))
        assertEquals("Adele", SongNames.artist("Adele VEVO"))
        assertEquals("A", SongNames.artist("A, B & C"))
        assertEquals("A", SongNames.artist("A feat. B"))
        assertEquals("Wham!", SongNames.artist("Wham!"))
    }
}
