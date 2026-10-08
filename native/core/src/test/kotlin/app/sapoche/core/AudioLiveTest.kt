package app.sapoche.core

import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assumptions.assumeTrue
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Asks the real YouTube which audio streams a song has, to check that the steps of [AudioQuality] still mean
 * something. It only runs with SAPOCHE_LIVE=1: `SAPOCHE_LIVE=1 ./gradlew :core:test --tests '*AudioLiveTest*'`.
 */
class AudioLiveTest {

    @Test
    fun `the steps of the sound quality give more sound as they go up`() = runBlocking {
        assumeTrue(System.getenv("SAPOCHE_LIVE") == "1", "set SAPOCHE_LIVE=1 to ask the real service")
        val sources = NewPipeResolver().resolve("lYBUbBu4W08").all
        println("[audio] " + sources.sortedBy { it.bitrateKbps }.joinToString { "itag ${it.itag} ${it.codec} ${it.bitrateKbps}kbps" })
        val steps = AudioQuality.entries.map { checkNotNull(it.choose(sources)) }
        println("[audio] steps: " + steps.joinToString { "${it.itag}=${it.bitrateKbps}kbps" })
        assertTrue(steps.zipWithNext().all { (lower, higher) -> lower.bitrateKbps <= higher.bitrateKbps }, "$steps")
        assertTrue(steps.first().bitrateKbps < steps.last().bitrateKbps, "a song has more than one stream: $steps")
    }
}
