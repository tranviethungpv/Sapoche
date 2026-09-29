package app.unison.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class YoutubeLinksTest {

    @Test
    fun `finds the video in the usual link shapes`() {
        val id = "bNp9pn0ni3I"
        assertEquals(id, YoutubeLinks.videoId("https://www.youtube.com/watch?v=$id"))
        assertEquals(id, YoutubeLinks.videoId("https://music.youtube.com/watch?v=$id&si=abc"))
        assertEquals(id, YoutubeLinks.videoId("https://m.youtube.com/watch?feature=share&v=$id"))
        assertEquals(id, YoutubeLinks.videoId("https://youtu.be/$id?t=42"))
        assertEquals(id, YoutubeLinks.videoId("https://www.youtube.com/shorts/$id"))
        assertEquals(id, YoutubeLinks.videoId(id))
    }

    @Test
    fun `search words are not mistaken for a video id`() {
        assertNull(YoutubeLinks.videoId("Radioactive"))
        assertNull(YoutubeLinks.videoId("son tung mtp"))
        assertNull(YoutubeLinks.videoId("https://example.com/watch?v=short"))
    }

    @Test
    fun `a playlist page gives its id but a video inside a playlist does not`() {
        val list = "PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf"
        assertEquals(list, YoutubeLinks.playlistId("https://www.youtube.com/playlist?list=$list"))
        assertEquals(list, YoutubeLinks.playlistId("https://music.youtube.com/playlist?list=$list&si=x"))
        assertNull(YoutubeLinks.playlistId("https://www.youtube.com/watch?v=bNp9pn0ni3I&list=$list"))
        assertEquals("bNp9pn0ni3I", YoutubeLinks.videoId("https://www.youtube.com/watch?v=bNp9pn0ni3I&list=$list"))
    }
}
