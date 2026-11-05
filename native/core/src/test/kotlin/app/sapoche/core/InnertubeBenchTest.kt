package app.sapoche.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assumptions.assumeTrue
import kotlin.test.Test

/**
 * Times the ways of getting the streams of a song against the real YouTube, on the same network: NewPipeExtractor, the
 * visionOS client with a new identity each time, and the same with an identity asked for in advance. It only runs with
 * SAPOCHE_NET_BENCH=1 and goes to the network, so `tool/check.sh` leaves it out:
 * `SAPOCHE_NET_BENCH=1 ./gradlew :core:test --tests '*InnertubeBenchTest*' -i`.
 */
class InnertubeBenchTest {

    private val songs = listOf(
        "dQw4w9WgXcQ", "bNp9pn0ni3I", "lYBUbBu4W08", "kJQP7kiw5Fk", "9bZkp7q19f0",
        "JGwWNGJdvx8", "fRh_vgS2dFE", "OPf0YbXqDm0", "RgKAFK5djSk", "hT_nvWreIhg",
    )

    private fun median(values: List<Long>) = values.sorted()[values.size / 2]

    @Test
    fun `how long the streams of ten songs take to get`() = runBlocking {
        assumeTrue(System.getenv("SAPOCHE_NET_BENCH") == "1", "set SAPOCHE_NET_BENCH=1 to ask the real service")
        val probe = Probe()
        val newPipe = NewPipeResolver()
        // The first lookup of a process also loads the extractor: it is not what a song costs
        newPipe.resolve(songs.first())

        val viaNewPipe = ArrayList<Long>()
        val viaVisionos = ArrayList<Long>()
        val viaPrefetched = ArrayList<Long>()
        val probeMs = ArrayList<Long>()
        val transport = OkHttpInnertube()
        val fresh1 = InnertubePlayer(transport = transport)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val prefetched = InnertubePlayer(transport = transport, visitors = PrefetchedVisitors(FreshVisitors(transport = transport), scope))
        for (id in songs) {
            val a = newPipe.resolve(id)
            viaNewPipe += a.resolveMs
            val b = fresh1.resolve(id)
            viaVisionos += b.resolveMs
            delay(1_500) // a song is not played the moment the one before it was; the next identity has come by then
            val c = prefetched.resolve(id)
            viaPrefetched += c.resolveMs
            val probed = probe.check(c.best)
            probeMs += probed.firstByteMs
            println("[bench] $id newpipe=${a.resolveMs}ms visionos=${b.resolveMs}ms (${b.steps}) prefetched=${c.resolveMs}ms probe=${probed.headStatus}/${probed.midStatus}/${probed.tailStatus} firstByte=${probed.firstByteMs}ms loudness=${c.best.loudnessDb}")
        }
        println("[bench] median newpipe=${median(viaNewPipe)}ms visionos=${median(viaVisionos)}ms prefetched=${median(viaPrefetched)}ms firstByte=${median(probeMs)}ms")
        println("[bench] max    newpipe=${viaNewPipe.max()}ms visionos=${viaVisionos.max()}ms prefetched=${viaPrefetched.max()}ms firstByte=${probeMs.max()}ms")
    }
}
