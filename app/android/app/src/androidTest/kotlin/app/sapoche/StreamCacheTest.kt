package app.sapoche

import app.sapoche.core.AudioSource
import app.sapoche.core.InnertubePlayer
import app.sapoche.core.PlaylistRef
import app.sapoche.core.Playlist
import app.sapoche.core.Probe
import app.sapoche.core.ProbeResult
import app.sapoche.core.Resolved
import app.sapoche.core.StreamResolver
import app.sapoche.core.TrackInfo
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class StreamCacheTest {

    private class Resolver(private val via: String) : StreamResolver {
        val asked = AtomicInteger()

        override suspend fun resolve(videoId: String): Resolved {
            val n = asked.incrementAndGet()
            val source = AudioSource("https://example.invalid/$videoId/$n", "M4A", 128, 1000, 140)
            return Resolved(TrackInfo(videoId, "t", "a", null, 60), source, listOf(source), 1, via = via)
        }

        override suspend fun search(query: String, limit: Int, songsOnly: Boolean) = emptyList<TrackInfo>()
        override suspend fun searchPlaylists(query: String, limit: Int) = emptyList<PlaylistRef>()
        override suspend fun playlist(playlistId: String, limit: Int) = Playlist("", emptyList())
        override suspend fun related(videoId: String, limit: Int) = emptyList<TrackInfo>()
        override suspend fun suggest(query: String) = emptyList<String>()
    }

    /** A probe that answers when the test says so, with the statuses it is given. */
    private class Gate(var status: Int = 206) : Probe() {
        val release = CompletableDeferred<Unit>()
        val started = CompletableDeferred<Unit>()

        override suspend fun check(source: AudioSource, userAgent: String): ProbeResult {
            started.complete(Unit)
            release.await()
            return ProbeResult(status, status, status, 1000, 5)
        }
    }

    @Test
    fun anAddressOfTheAppApiIsUsedBeforeItsProbeIsDone() {
        val resolver = Resolver(InnertubePlayer.VIA)
        val gate = Gate()
        val cache = StreamCache(resolver, gate)
        // The probe is held back, and the address comes all the same
        assertEquals("https://example.invalid/a/1", cache.get("a"))
        assertEquals(1, resolver.asked.get())
        gate.release.complete(Unit)
    }

    @Test
    fun anAddressTheProbeFindsBrokenIsForgottenAndTheNextAskResolvesAgain() = runBlocking {
        val resolver = Resolver(InnertubePlayer.VIA)
        val gate = Gate(status = 403)
        val cache = StreamCache(resolver, gate)
        assertEquals("https://example.invalid/a/1", cache.get("a"))
        gate.started.await()
        gate.release.complete(Unit)
        // The probe runs beside the caller: wait for it to have its say
        var url = cache.get("a")
        repeat(100) {
            if (url.endsWith("/2")) return@repeat
            Thread.sleep(20)
            url = cache.get("a")
        }
        assertEquals("https://example.invalid/a/2", url)
    }

    @Test
    fun anAddressOfTheSlowWayWaitsForItsProbe() {
        val resolver = Resolver("newpipe")
        val gate = Gate()
        gate.release.complete(Unit)
        val cache = StreamCache(resolver, gate)
        assertEquals("https://example.invalid/a/1", cache.get("a"))
        assertTrue(gate.started.isCompleted)
    }

    @Test
    fun anAddressOfTheSlowWayThatFailsItsProbeIsResolvedAgain() {
        val resolver = Resolver("newpipe")
        val gate = Gate(status = 403)
        gate.release.complete(Unit)
        val cache = StreamCache(resolver, gate)
        try {
            cache.get("a")
        } catch (e: StreamCache.ResolveFailed) {
            assertEquals(3, resolver.asked.get())
            return
        }
        throw AssertionError("a broken address must not be handed out")
    }
}
