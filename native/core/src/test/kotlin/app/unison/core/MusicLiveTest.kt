package app.unison.core

import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assumptions.assumeTrue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Asks the real YouTube Music and LRCLIB. It only runs with UNISON_LIVE=1, because the network is not always
 * there and the answers change; run it when the readers may have gone out of date:
 * `UNISON_LIVE=1 ./gradlew :core:test --tests '*MusicLiveTest*'`.
 */
class MusicLiveTest {

    private fun live() = assumeTrue(System.getenv("UNISON_LIVE") == "1", "set UNISON_LIVE=1 to ask the real services")

    @Test
    fun `the radio, related page, lyrics and artist of a real song are read`() = runBlocking {
        live()
        val music = MusicClient()
        val next = music.watchNext("lYBUbBu4W08")
        assertEquals("Never Gonna Give You Up", next.tracks.first().title)
        assertTrue(next.tracks.size > 10, "a radio has many songs, not ${next.tracks.size}")
        val related = music.related(assertNotNull(next.relatedId))
        assertTrue(related.more.isNotEmpty() && related.artists.isNotEmpty())
        assertTrue(assertNotNull(music.lyrics(assertNotNull(next.lyricsId))).isNotBlank())
        val artist = music.artist(assertNotNull(next.tracks.first().artistId))
        assertEquals("Rick Astley", artist.name)
        assertTrue(artist.topSongs.isNotEmpty() && artist.albums.isNotEmpty())
    }

    @Test
    fun `searching by songs and by videos tells them apart`() = runBlocking {
        live()
        val music = MusicClient()
        assertTrue(music.searchSongs("Never Gonna Give You Up Rick Astley").first().isSong)
        assertTrue(music.searchVideos("Never Gonna Give You Up Rick Astley").none { it.isSong })
        assertTrue(music.trending().isNotEmpty())
    }

    @Test
    fun `lyrics with times are found for an English and a Vietnamese song`() = runBlocking {
        live()
        val lyrics = LyricsClient()
        assertTrue(assertNotNull(lyrics.find("Never Gonna Give You Up", "Rick Astley", 214)).let { it.synced || it.plain != null })
        assertTrue(assertNotNull(lyrics.find("Chúng Ta Của Hiện Tại", "Sơn Tùng M-TP", 302)).synced)
    }
}
