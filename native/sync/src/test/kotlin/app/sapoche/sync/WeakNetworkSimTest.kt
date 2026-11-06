package app.sapoche.sync

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * A player in front of a network of a given speed: it buffers at what the network delivers, stalls when it runs dry and
 * plays again after a few seconds of buffer, and loads again from a new connection when seeked outside what it holds.
 * Mirrors what ExoPlayer does with the room's loading settings (2.5 s to start, 5 s after a stall, no back buffer).
 */
internal class NetworkPlayer(
    private val now: () -> Long,
    private val kbpsAt: (Long) -> Int,
    private val bitrateKbps: Int = 160,
    private val durationMs: Long = 600_000,
) : PlayerPort {
    var loaded: QueueItem? = null
    private var position = 0.0
    private var until = 0.0
    private var connectAt = 0L
    private var wantsPlay = false
    private var audible = false
    private var needMs = START_BUFFER_MS
    private var speed = 1f
    private var last = now()

    var interruptions = 0
        private set
    var silentMs = 0L
        private set
    val seeks = mutableListOf<Pair<Long, Boolean>>() // when, outside what was held
    override var onEnded: (() -> Unit)? = null
    override var onAdvanced: (() -> Unit)? = null
    override var onError: ((Exception) -> Unit)? = null

    private fun advance() {
        val t = now()
        var at = last
        while (at < t) {
            val dt = minOf(STEP_MS, t - at)
            if (loaded != null) {
                if (at >= connectAt) until = minOf(durationMs.toDouble(), until + dt * kbpsAt(at).toDouble() / bitrateKbps)
                if (audible) {
                    position += dt * speed
                    if (position >= until && until < durationMs) {
                        position = until
                        audible = false
                        interruptions++
                        needMs = REBUFFER_MS
                    }
                } else if (wantsPlay && until - position >= minOf(needMs.toDouble(), durationMs - position)) {
                    audible = true
                }
                if (wantsPlay && !audible) silentMs += dt
            }
            at += dt
        }
        last = t
    }

    private fun connectAgain(to: Long) {
        position = to.toDouble()
        until = to.toDouble()
        connectAt = now() + CONNECT_MS
        needMs = START_BUFFER_MS
        if (audible) interruptions++
        audible = false
    }

    private suspend fun awaitReady(timeoutMs: Long) {
        val by = now() + timeoutMs
        while (now() < by) {
            advance()
            if (until - position >= minOf(START_BUFFER_MS.toDouble(), durationMs - position)) return
            delay(STEP_MS)
        }
    }

    override suspend fun prepare(item: QueueItem, seekToMs: Long) {
        delay(RESOLVE_MS)
        advance()
        loaded = item
        wantsPlay = false
        connectAgain(seekToMs)
        awaitReady(20_000)
    }

    override fun refresh(videoId: String) = Unit

    override suspend fun seekTo(positionMs: Long) {
        advance()
        val held = positionMs >= position && positionMs <= until
        seeks += now() to !held
        if (held) {
            position = positionMs.toDouble()
        } else {
            connectAgain(positionMs)
            awaitReady(SEEK_TIMEOUT_MS)
        }
    }

    override fun play() {
        advance()
        wantsPlay = true
    }

    override fun pause() {
        advance()
        wantsPlay = false
        audible = false
    }

    override fun stop() {
        advance()
        wantsPlay = false
        audible = false
        loaded = null
    }

    override fun setSpeed(speed: Float) {
        advance()
        this.speed = speed
    }

    override fun setNext(item: QueueItem?) = Unit

    override fun positionMs(): Long {
        advance()
        return position.toLong()
    }

    override fun isPlaying(): Boolean {
        advance()
        return audible
    }

    override fun isBuffering(): Boolean {
        advance()
        return wantsPlay && !audible
    }

    override fun bufferedPositionMs(): Long {
        advance()
        return until.toLong()
    }

    private companion object {
        const val STEP_MS = 50L
        const val START_BUFFER_MS = 2_500L
        const val REBUFFER_MS = 5_000L
        const val CONNECT_MS = 300L
        const val RESOLVE_MS = 500L
        const val SEEK_TIMEOUT_MS = 8_000L
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class WeakNetworkSimTest {
    private val item = QueueItem("q1", "bNp9pn0ni3I", "Song", "Artist", null, 600_000, "dev-a")

    /** What a five minute listen to the room looked like from one device. */
    private class Outcome(val interruptions: Int, val silentMs: Long, val seeks: Int, val outsideSeeks: Int, val worstLagMs: Long, val lateLagMs: Long, val lastWeak: Boolean) {
        override fun toString() = "interruptions=$interruptions silent=${silentMs}ms seeks=$seeks (outside the buffer: $outsideSeeks) worstLag=${worstLagMs}ms lagAtEnd=${lateLagMs}ms"
    }

    /** [kbps] with a [forMs] drop to nothing that begins [at] into every [everyMs]. */
    private fun outages(kbps: Int, everyMs: Long = 40_000, forMs: Long = 15_000, at: Long = 5_000): (Long) -> Int =
        { t -> if (t % everyMs in at until at + forMs) 0 else kbps }

    private fun TestScope.listen(kbpsAt: (Long) -> Int, durationMs: Long = 300_000): Outcome {
        val player = NetworkPlayer({ currentTime }, kbpsAt)
        val clock = ClockSync().apply { addSample(c0 = 0, c2 = 20, s1 = 5000 + 10) }
        val session = GroupSession(backgroundScope, player, clock, { currentTime }, {})
        fun serverNow() = clock.toServer(currentTime)
        session.onMessage(ServerMessage.Prepare(epoch = 1, index = 0, item = item, seekToMs = 0))
        runCurrent()
        advanceTimeBy(3_000)
        runCurrent()
        val startAt = serverNow() + 1500
        session.onMessage(ServerMessage.Start(epoch = 1, startAt = startAt, positionMs = 0))
        var worst = 0L
        var lag = 0L
        val begin = currentTime
        val stallsBefore = player.interruptions
        val silentBefore = player.silentMs
        while (currentTime - begin < durationMs) {
            advanceTimeBy(1000)
            runCurrent()
            lag = (serverNow() - startAt) - player.positionMs()
            worst = maxOf(worst, lag)
        }
        return Outcome(
            player.interruptions - stallsBefore, player.silentMs - silentBefore, player.seeks.size, player.seeks.count { it.second },
            worst, lag, session.snapshot.value.weak,
        )
    }

    @Test
    fun `a network that is enough but drops out does not make the device stall in a chain`() = runTest {
        val outcome = listen(outages(kbps = 300))
        println("SIM chappy: $outcome")
        // 8 drops in five minutes: each one may stall the device once, not again and again after it
        assertTrue(outcome.interruptions <= 8, "stalled ${outcome.interruptions} times: $outcome")
        assertEquals(0, outcome.outsideSeeks, "seeked out of what it held: $outcome")
        assertTrue(outcome.worstLagMs <= NetworkHealth.MAX_LAG_MS + 3_000, "fell too far behind: $outcome")
    }

    @Test
    fun `a good network is untouched`() = runTest {
        val outcome = listen({ 2000 })
        println("SIM good: $outcome")
        assertEquals(0, outcome.interruptions, "$outcome")
        assertTrue(!outcome.lastWeak)
        assertTrue(abs(outcome.lateLagMs) < 120, "$outcome")
    }
}
