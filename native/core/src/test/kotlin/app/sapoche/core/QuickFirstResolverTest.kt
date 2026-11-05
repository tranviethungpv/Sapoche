package app.sapoche.core

import kotlinx.coroutines.test.runTest
import org.schabi.newpipe.extractor.exceptions.ContentNotAvailableException
import java.io.IOException
import java.net.UnknownHostException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class QuickFirstResolverTest {

    private fun resolved(via: String) = Resolved(
        track = TrackInfo("x", "t", "a", null, 60),
        best = AudioSource("https://example.invalid/a", "M4A", 128, 1000, 140),
        all = emptyList(), resolveMs = 1, via = via,
    )

    private class Full(private val answer: () -> Resolved) : StreamResolver {
        var asked = 0
        override suspend fun resolve(videoId: String): Resolved { asked++; return answer() }
        override suspend fun search(query: String, limit: Int, songsOnly: Boolean) = emptyList<TrackInfo>()
        override suspend fun searchPlaylists(query: String, limit: Int) = emptyList<PlaylistRef>()
        override suspend fun playlist(playlistId: String, limit: Int) = Playlist("", emptyList())
        override suspend fun related(videoId: String, limit: Int) = emptyList<TrackInfo>()
        override suspend fun suggest(query: String) = emptyList<String>()
    }

    @Test
    fun `the quick way is used when it works`() = runTest {
        val full = Full { resolved("newpipe") }
        assertEquals("visionos", QuickFirstResolver({ resolved("visionos") }, full).resolve("x").via)
        assertEquals(0, full.asked)
    }

    @Test
    fun `any failure of the quick way falls back to NewPipe`() = runTest {
        val log = ArrayList<String>()
        val full = Full { resolved("newpipe") }
        for (failure in listOf(InnertubeRefused("bot check", "LOGIN_REQUIRED"), IOException("503"), IllegalStateException("odd answer"))) {
            assertEquals("newpipe", QuickFirstResolver({ throw failure }, full, log::add).resolve("x").via)
        }
        assertEquals(3, full.asked)
        assertTrue(log.all { it.contains("x quick way failed") })
    }

    @Test
    fun `only NewPipe says that a song cannot be played`() = runTest {
        val full = Full { throw ContentNotAvailableException("removed") }
        assertFailsWith<ContentNotAvailableException> { QuickFirstResolver({ throw InnertubeRefused("unavailable", "UNPLAYABLE") }, full).resolve("x") }
        assertEquals(1, full.asked)
    }

    @Test
    fun `without a network NewPipe is not asked as well`() = runTest {
        val full = Full { resolved("newpipe") }
        assertFailsWith<IOException> { QuickFirstResolver({ throw IOException("failed", UnknownHostException("youtubei.googleapis.com")) }, full).resolve("x") }
        assertEquals(0, full.asked)
    }
}
