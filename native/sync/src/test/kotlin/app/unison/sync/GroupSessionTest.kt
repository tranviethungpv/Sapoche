package app.unison.sync

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** A player whose position advances with virtual time, so timing can be asserted to the millisecond. */
private class FakePlayer(private val now: () -> Long) : PlayerPort {
    var loaded: QueueItem? = null
    var position = 0L
    var playing = false
    var currentSpeed = 1f
    var playedAtLocal: Long? = null
    var prepareCount = 0
    var prepareDelayMs = 0L
    var failPrepare = false
    val seeks = mutableListOf<Long>()
    private var lastUpdate = now()

    override var onEnded: (() -> Unit)? = null
    override var onAdvanced: (() -> Unit)? = null
    var queuedNext: QueueItem? = null
    override var onError: ((Exception) -> Unit)? = null

    /** Sound only starts moving this long after play(), like real audio output latency. */
    var startLatencyMs = 0L
    private var holdUntil = 0L

    private fun advance() {
        val t = now()
        if (playing) {
            val from = maxOf(lastUpdate, holdUntil)
            if (t > from) position += ((t - from) * currentSpeed).toLong()
        }
        lastUpdate = t
    }

    override suspend fun prepare(item: QueueItem, seekToMs: Long) {
        delay(prepareDelayMs)
        if (failPrepare) error("cannot load")
        prepareCount++
        advance()
        loaded = item
        queuedNext = null
        position = seekToMs
        playing = false
    }

    override suspend fun seekTo(positionMs: Long) {
        advance()
        position = positionMs
        seeks += positionMs
    }

    override fun play() {
        advance()
        playing = true
        playedAtLocal = now()
        holdUntil = now() + startLatencyMs
    }

    override fun pause() {
        advance()
        playing = false
    }

    override fun stop() {
        advance()
        playing = false
        loaded = null
    }

    override fun setSpeed(speed: Float) {
        advance()
        this.currentSpeed = speed
    }

    override fun setNext(item: QueueItem?) {
        if (loaded != null) queuedNext = item
    }

    /** Test hook: the current item ran out and the queued next one started by itself. */
    fun autoAdvance() {
        advance()
        val successor = queuedNext ?: return
        loaded = successor
        queuedNext = null
        position = 0
        onAdvanced?.invoke()
    }

    override fun positionMs(): Long {
        advance()
        return position
    }

    override fun isPlaying(): Boolean = playing

    /** Test hook: shove the position, as if the device drifted. */
    fun nudge(deltaMs: Long) {
        advance()
        position += deltaMs
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class GroupSessionTest {

    private val item = QueueItem("q1", "bNp9pn0ni3I", "Song", "Artist", null, 200_000, "dev-a")
    private val item2 = QueueItem("q2", "UoXllQoqEBY", "Song 2", "Artist", null, 180_000, "dev-a")

    private class Harness(scope: TestScope, serverOffsetMs: Long) {
        val now: () -> Long = { scope.currentTime }
        val clock = ClockSync().apply {
            // rtt 20ms, server clock reads local + serverOffsetMs
            addSample(c0 = 0, c2 = 20, s1 = serverOffsetMs + 10)
        }
        val player = FakePlayer(now)
        val sent = mutableListOf<String>()
        val session = GroupSession(scope.backgroundScope, player, clock, now, { sent += it })

        fun serverNow() = clock.toServer(now())
    }

    private fun TestScope.harness(offset: Long = 5000) = Harness(this, offset)

    private fun state(phase: String, epoch: Long, startedAt: Long = 0, positionMs: Long = 0) = ServerMessage.State(
        serverNow = 0,
        you = "dev-a",
        state = RoomState(listOf(item), 0, phase, startedAt, positionMs, epoch),
        members = emptyList(),
    )

    private fun TestScope.step(ms: Long) {
        advanceTimeBy(ms)
        runCurrent()
    }

    @Test
    fun `reports ready after preparing and starts exactly at the scheduled server time`() = runTest {
        val h = harness(offset = 5000)
        h.session.onMessage(ServerMessage.Prepare(epoch = 1, index = 0, item = item, seekToMs = 0))
        runCurrent()
        assertEquals(item, h.player.loaded)
        assertTrue(h.sent.any { it.contains("\"ready\"") && it.contains("\"epoch\":1") })

        // Start is scheduled 1500ms ahead on the server clock
        h.session.onMessage(ServerMessage.Start(epoch = 1, startAt = h.serverNow() + 1500, positionMs = 0))
        step(1499)
        assertFalse(h.player.playing, "must not start early")
        step(1)
        assertTrue(h.player.playing)
        assertEquals(1500L, h.player.playedAtLocal)
    }

    @Test
    fun `a device that arrives late skips ahead instead of starting from zero`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        step(3000)
        // The start moment was 2000ms ago
        h.session.onMessage(ServerMessage.Start(1, startAt = h.serverNow() - 2000, positionMs = 0))
        runCurrent()
        assertTrue(h.player.playing)
        assertTrue(abs(h.player.position - 2150) <= 200, "expected about 2150ms, was ${h.player.position}")
    }

    @Test
    fun `a slow device finishes its own preparation before starting`() = runTest {
        val h = harness()
        h.player.prepareDelayMs = 3000
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        // The barrier timed out on the server and released the start while we are still loading
        h.session.onMessage(ServerMessage.Start(1, startAt = h.serverNow() + 1500, positionMs = 0))
        step(2000)
        assertFalse(h.player.playing, "still loading")
        step(1500)
        assertTrue(h.player.playing)
        val expected = h.serverNow() - (1500 + 5000) // server time minus startAt... position since scheduled start
        assertTrue(abs(h.player.position - (h.now() - 1500)) < 400, "position ${h.player.position} vs ${h.now() - 1500} (expected~$expected)")
    }

    @Test
    fun `small drift is corrected by nudging speed and speed returns to normal`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(1500)
        step(1000)
        h.player.nudge(+120) // this device is now 120ms ahead
        step(5000)
        assertEquals(0.97f, h.player.currentSpeed, "ahead: must slow down")
        step(12000)
        assertEquals(1f, h.player.currentSpeed, "back to normal once aligned")
        val drift = h.player.positionMs() - (h.serverNow() - (h.serverNow() - (h.now() - 1500)))
        assertTrue(abs(drift) < 50, "still off by ${drift}ms")
        assertTrue(h.player.seeks.size <= 1, "no correction seeks expected, got ${h.player.seeks}")
    }

    @Test
    fun `a device that is behind speeds up`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(2500)
        h.player.nudge(-150)
        step(5000)
        assertEquals(1.03f, h.player.currentSpeed)
    }

    @Test
    fun `large drift is corrected by seeking`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(2500)
        val seeksBefore = h.player.seeks.size
        h.player.nudge(+1500)
        step(2500)
        assertTrue(h.player.seeks.size > seeksBefore, "expected a corrective seek")
        assertEquals(1f, h.player.currentSpeed)
        val expected = h.now() - 1500
        assertTrue(abs(h.player.positionMs() - expected) < 250, "position ${h.player.positionMs()} vs $expected")
    }

    @Test
    fun `the snapshot follows start and pause even though the server sends no state for them`() = runTest {
        val h = harness()
        h.session.onMessage(state("preparing", epoch = 1))
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        assertEquals("preparing", h.session.snapshot.value.state?.phase)

        val startAt = h.serverNow() + 1500
        h.session.onMessage(ServerMessage.Start(1, startAt, 0))
        runCurrent()
        assertEquals("playing", h.session.snapshot.value.state?.phase)
        assertEquals(startAt, h.session.snapshot.value.state?.startedAt)

        h.session.onMessage(ServerMessage.Pause(epoch = 2, positionMs = 2400))
        runCurrent()
        assertEquals("paused", h.session.snapshot.value.state?.phase)
        assertEquals(2400L, h.session.snapshot.value.state?.positionMs)
    }

    @Test
    fun `pause stops playback at the given position`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(4000)
        h.session.onMessage(ServerMessage.Pause(epoch = 2, positionMs = 2400))
        runCurrent()
        assertFalse(h.player.playing)
        assertEquals(2400L, h.player.position)
        step(5000)
        assertEquals(2400L, h.player.position, "stays put while paused")
    }

    @Test
    fun `messages from an older epoch are ignored`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(epoch = 5, index = 0, item = item, seekToMs = 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(epoch = 3, startAt = h.serverNow() + 100, positionMs = 0))
        step(1000)
        assertFalse(h.player.playing)
    }

    @Test
    fun `a failed preparation is reported instead of blocking the room`() = runTest {
        val h = harness()
        h.player.failPrepare = true
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        assertTrue(h.sent.any { it.contains("resolveFailed") && it.contains("\"epoch\":1") })
        assertFalse(h.sent.any { it.contains("\"ready\"") })
    }

    @Test
    fun `joining a room that is already playing lands on the current position`() = runTest {
        val h = harness()
        step(1000)
        // Position 0 was played 10 seconds ago
        val startedAt = h.serverNow() - 10_000
        h.session.onMessage(state("playing", epoch = 4, startedAt = startedAt))
        step(2000)
        assertTrue(h.player.playing)
        step(1000)
        val expected = h.serverNow() - startedAt
        assertTrue(abs(h.player.positionMs() - expected) < 300, "position ${h.player.positionMs()} vs expected $expected")
    }

    @Test
    fun `reconnecting into the same epoch does not disturb playback`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(3000)
        val seeksBefore = h.player.seeks.size
        // After a reconnect the server sends the current state again, with the same epoch
        h.session.onMessage(state("playing", epoch = 1, startedAt = h.serverNow() - 1500))
        step(1000)
        assertTrue(h.player.playing)
        assertEquals(seeksBefore, h.player.seeks.size)
    }

    @Test
    fun `reports the end of an item once`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(2000)
        assertNotNull(h.player.onEnded)
        h.player.onEnded?.invoke()
        runCurrent()
        assertEquals(1, h.sent.count { it.contains("\"ended\"") && it.contains("\"epoch\":1") })
    }

    @Test
    fun `a stream that breaks mid-track is reloaded and rejoins the room position`() = runTest {
        val h = harness()
        // The session needs the room state to know which item is playing
        h.session.onMessage(state("preparing", epoch = 1))
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        val startAt = h.serverNow() + 1500
        h.session.onMessage(ServerMessage.Start(1, startAt, 0))
        step(6000)
        assertTrue(h.player.playing)

        // Simulate the player dying and losing its item, like an ExoPlayer error does
        h.player.playing = false
        h.player.loaded = null
        h.player.onError?.invoke(RuntimeException("403"))
        step(3000)

        assertEquals(item, h.player.loaded, "reloaded")
        assertTrue(h.player.playing, "playing again")
        val expected = h.serverNow() - startAt
        assertTrue(abs(h.player.positionMs() - expected) < 400, "position ${h.player.positionMs()} vs $expected")
    }

    @Test
    fun `a stream that keeps failing is abandoned after a few recoveries`() = runTest {
        val h = harness()
        h.session.onMessage(state("preparing", epoch = 1))
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(3000)
        var recoveredLoads = 0
        repeat(10) {
            h.player.playing = false
            h.player.loaded = null
            h.player.onError?.invoke(RuntimeException("403"))
            step(2500)
            if (h.player.loaded != null) recoveredLoads++
        }
        assertEquals(5, recoveredLoads, "exactly the allowed number of recoveries")
    }

    @Test
    fun `a new prepare interrupts playing`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(3000)
        assertTrue(h.player.playing)
        h.session.onMessage(ServerMessage.Prepare(2, 0, item.copy(id = "q2"), 0))
        runCurrent()
        assertFalse(h.player.playing)
        assertTrue(h.sent.any { it.contains("\"ready\"") && it.contains("\"epoch\":2") })
    }

    // ------------------------------------------------------------------ gapless advance

    private fun twoItemState(phase: String, epoch: Long, index: Int = 0, startedAt: Long = 0) = ServerMessage.State(
        serverNow = 0,
        you = "dev-a",
        state = RoomState(listOf(item, item2), index, phase, startedAt, 0, epoch),
        members = emptyList(),
    )

    /** Room with two queued items, item 1 playing since server time 0 on epoch 1. */
    private fun TestScope.playingFirstOfTwo(): Harness {
        val h = harness()
        h.session.onMessage(twoItemState("preparing", 1))
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(1500)
        return h
    }

    @Test
    fun `the next item is handed to the player while following the room`() = runTest {
        val h = playingFirstOfTwo()
        assertEquals(item2, h.player.queuedNext)
    }

    @Test
    fun `no successor is queued while repeating one item`() = runTest {
        val h = harness()
        val two = { repeat: String ->
            ServerMessage.State(
                serverNow = 0, you = "dev-a", members = emptyList(),
                state = RoomState(listOf(item, item2), 0, "playing", h.serverNow() - 5000, 0, 1, repeat),
            )
        }
        h.session.onMessage(two("off"))
        runCurrent()
        step(3000)
        assertEquals(item2, h.player.queuedNext, "the successor is preloaded as usual")

        h.session.onMessage(two("one"))
        runCurrent()
        assertEquals(null, h.player.queuedNext, "repeating one item must not slip into the next one")

        h.session.onMessage(two("all"))
        runCurrent()
        assertEquals(item2, h.player.queuedNext)
    }

    @Test
    fun `no successor is queued after the last item`() = runTest {
        val h = harness()
        h.session.onMessage(state("preparing", 1))
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(1500)
        assertEquals(null, h.player.queuedNext)
    }

    @Test
    fun `a track added later becomes the successor`() = runTest {
        val h = harness()
        h.session.onMessage(state("preparing", 1))
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(1500)
        h.session.onMessage(twoItemState("playing", 1, startedAt = h.serverNow() - 1500))
        runCurrent()
        assertEquals(item2, h.player.queuedNext)
    }

    @Test
    fun `moving on by itself is reported once the position has settled`() = runTest {
        val h = playingFirstOfTwo()
        step(5000)
        h.player.autoAdvance()
        step(900)
        assertTrue(h.sent.none { it.contains("\"advanced\"") }, "must wait before reporting")
        step(200)
        val report = h.sent.single { it.contains("\"advanced\"") }
        assertTrue(report.contains("\"itemId\":\"q2\"") && report.contains("\"epoch\":1"), report)
        val startedAt = Regex("\"startedAt\":(-?\\d+)").find(report)!!.groupValues[1].toLong()
        // Position 0 was heard about 1100ms ago
        assertTrue(abs(startedAt - (h.serverNow() - 1100)) < 60, "startedAt=$startedAt now=${h.serverNow()}")
    }

    @Test
    fun `the room's advance is adopted and drift correction carries on`() = runTest {
        val h = playingFirstOfTwo()
        step(5000)
        h.player.autoAdvance()
        step(1100)
        h.session.onMessage(ServerMessage.Advance(epoch = 2, index = 1, startedAt = h.serverNow() - 1100))
        step(6000)
        assertEquals(item2, h.player.loaded)
        assertEquals(1, h.player.prepareCount, "no reload for a device that advanced by itself")
        assertEquals(1f, h.player.currentSpeed)
        assertTrue(h.player.seeks.size <= 1, "no corrective seeks expected: ${h.player.seeks}")
        assertEquals(1L, h.session.snapshot.value.state?.index?.toLong())
    }

    @Test
    fun `an advance that arrives before the local player advances waits for it`() = runTest {
        val h = playingFirstOfTwo()
        step(5000)
        // The room already knows: item 2 starts 100ms from now
        h.session.onMessage(ServerMessage.Advance(epoch = 2, index = 1, startedAt = h.serverNow() + 100))
        step(100)
        h.player.autoAdvance()
        step(6000)
        assertTrue(h.sent.none { it.contains("\"advanced\"") }, "nothing to report, the room already knew")
        assertEquals(1, h.player.prepareCount)
        assertEquals(1f, h.player.currentSpeed)
        assertTrue(h.player.seeks.size <= 1, "no corrective seeks expected: ${h.player.seeks}")
    }

    @Test
    fun `a player that never advances is reloaded at the room's position`() = runTest {
        val h = playingFirstOfTwo()
        step(5000)
        h.session.onMessage(ServerMessage.Advance(epoch = 2, index = 1, startedAt = h.serverNow() - 500))
        step(6000)
        assertEquals(item2, h.player.loaded)
        assertEquals(2, h.player.prepareCount)
        assertTrue(h.player.playing)
    }

    @Test
    fun `a stale advance is ignored`() = runTest {
        val h = playingFirstOfTwo()
        step(1000)
        h.session.onMessage(ServerMessage.Advance(epoch = 1, index = 1, startedAt = h.serverNow()))
        step(6000)
        assertEquals(item, h.player.loaded)
    }

    // ------------------------------------------------------------------ resilience

    @Test
    fun `reconnecting to a room that is on the same item does not reload it`() = runTest {
        val h = playingFirstOfTwo()
        step(4000)
        val startedAt = h.serverNow() - 4000
        h.session.onMessage(twoItemState("playing", epoch = 2, startedAt = startedAt))
        step(3000)
        assertEquals(1, h.player.prepareCount, "the item must stay loaded")
        assertTrue(h.player.playing)
    }

    @Test
    fun `reconnecting after being paused locally resumes playback`() = runTest {
        val h = playingFirstOfTwo()
        step(4000)
        h.player.pause() // e.g. audio focus lost during the outage
        step(2000)
        val startedAt = h.serverNow() - 6000
        h.session.onMessage(twoItemState("playing", epoch = 2, startedAt = startedAt))
        step(1000)
        assertTrue(h.player.playing)
        assertEquals(1, h.player.prepareCount)
        val expected = h.now() - 1500
        assertTrue(abs(h.player.position - expected) < 400, "position ${h.player.position} vs $expected")
    }

    @Test
    fun `a repeated prepare for an item that is already loaded only reports ready again`() = runTest {
        val h = harness()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.sent.clear()
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        assertEquals(1, h.player.prepareCount)
        assertTrue(h.sent.any { it.contains("\"ready\"") })
    }

    @Test
    fun `start latency is learned and the next start lands on time`() = runTest {
        val h = harness()
        h.player.startLatencyMs = 300
        h.session.onMessage(twoItemState("preparing", 1))
        h.session.onMessage(ServerMessage.Prepare(1, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(1, h.serverNow() + 1500, 0))
        step(1500 + 6000)
        assertTrue(abs(h.session.startBiasMs - 240) <= 80, "learned ${h.session.startBiasMs}")

        // The next start aims ahead by the learned bias, so the first readings are already close
        h.session.onMessage(ServerMessage.Prepare(2, 0, item, 0))
        runCurrent()
        h.session.onMessage(ServerMessage.Start(2, h.serverNow() + 1500, 0))
        step(1500 + 1000)
        // Position 0 was due 1000ms ago
        val drift = h.player.positionMs() - 1000
        assertTrue(abs(drift) < 100, "drift $drift, expected around 0 (bias ${h.session.startBiasMs})")
    }

    @Test
    fun `a failed catch-up load is retried until the network is back`() = runTest {
        val h = harness()
        h.player.failPrepare = true
        h.session.onMessage(twoItemState("playing", epoch = 1, startedAt = h.serverNow() - 10_000))
        step(12_000)
        assertFalse(h.player.playing, "still offline")
        h.player.failPrepare = false
        step(6000)
        assertTrue(h.player.playing)
        assertEquals(item, h.player.loaded)
        // The room started 10s before t=0, so its position is the local time plus 10s
        val roomPosition = h.now() + 10_000
        assertTrue(abs(h.player.position - roomPosition) < 600, "position ${h.player.position} vs $roomPosition")
    }

    @Test
    fun `recoveries are forgotten after a long healthy stretch`() = runTest {
        val h = playingFirstOfTwo()
        step(2000)
        repeat(4) { h.player.onError?.invoke(RuntimeException("boom")); step(4000) }
        step(40_000) // healthy for a while
        repeat(4) { h.player.onError?.invoke(RuntimeException("boom")); step(4000) }
        assertTrue(h.player.playing, "would have given up if the count was never reset")
    }

    @Test
    fun `a device trim shifts where the device aims`() = runTest {
        val h = playingFirstOfTwo()
        h.session.trimMs = 100 // this device is heard 100ms late, so it must run 100ms ahead
        step(5000)
        assertEquals(1.03f, h.player.currentSpeed, "an exactly aligned player is 100ms behind its target")
    }

    // ---- listening alone ----

    @Test
    fun `going solo keeps the song playing and tells the room`() = runTest {
        val h = playingFirstOfTwo()
        step(2000)
        h.session.goSolo()
        step(1000)
        assertTrue(h.player.playing, "going solo must not interrupt what is playing")
        assertTrue(h.sent.any { it.contains("\"solo\"") && it.contains("true") })
        assertTrue(h.session.snapshot.value.solo)
        assertEquals("q1", h.session.snapshot.value.soloItemId)
    }

    @Test
    fun `while alone the room pausing does not pause this device`() = runTest {
        val h = playingFirstOfTwo()
        h.session.goSolo()
        step(500)
        h.session.onMessage(ServerMessage.Pause(epoch = 2, positionMs = 5000, by = "dev-b"))
        step(1000)
        assertTrue(h.player.playing)
        assertEquals("paused", h.session.snapshot.value.state?.phase, "the view still shows what the room did")
    }

    @Test
    fun `while alone the room skipping does not move this device or hold the room back`() = runTest {
        val h = playingFirstOfTwo()
        h.session.goSolo()
        step(500)
        h.sent.clear()
        h.session.onMessage(ServerMessage.Prepare(epoch = 2, index = 1, item = item2, seekToMs = 0, by = "dev-b"))
        step(1000)
        assertEquals(item, h.player.loaded)
        assertTrue(h.player.playing)
        assertFalse(h.sent.any { it.contains("\"ready\"") }, "a solo device does not answer the barrier")
    }

    @Test
    fun `alone, next moves along the queue on this device only`() = runTest {
        val h = playingFirstOfTwo()
        h.session.goSolo()
        step(500)
        h.sent.clear()
        h.session.soloNext()
        step(500)
        assertEquals(item2, h.player.loaded)
        assertTrue(h.player.playing)
        assertEquals("q2", h.session.snapshot.value.soloItemId)
        assertFalse(h.sent.any { it.contains("\"next\"") })
    }

    @Test
    fun `alone, pausing pauses only this device`() = runTest {
        val h = playingFirstOfTwo()
        h.session.goSolo()
        step(500)
        h.sent.clear()
        h.session.soloPause()
        step(100)
        assertFalse(h.player.playing)
        assertTrue(h.sent.isEmpty(), "nothing is sent to the room")
        h.session.soloPlay()
        step(100)
        assertTrue(h.player.playing)
    }

    @Test
    fun `alone, a song ending moves on by itself and reports nothing`() = runTest {
        val h = playingFirstOfTwo()
        h.session.goSolo()
        step(500)
        assertEquals(item2, h.player.queuedNext, "the next song is preloaded for a gapless finish")
        h.sent.clear()
        h.player.autoAdvance()
        step(500)
        assertEquals("q2", h.session.snapshot.value.soloItemId)
        assertTrue(h.sent.none { it.contains("\"advanced\"") || it.contains("\"ended\"") })
    }

    @Test
    fun `alone, the last song ending stops instead of looping`() = runTest {
        val h = playingFirstOfTwo()
        h.session.goSolo()
        step(500)
        h.session.soloNext()
        step(500)
        h.player.onEnded?.invoke()
        step(500)
        assertFalse(h.player.playing)
    }

    @Test
    fun `rejoining asks the room for its state and follows it`() = runTest {
        val h = playingFirstOfTwo()
        h.session.goSolo()
        step(500)
        h.session.soloNext() // now on item 2 while the room is still on item 1
        step(500)
        h.sent.clear()
        h.session.rejoin()
        step(100)
        assertTrue(h.sent.any { it.contains("\"solo\"") && it.contains("false") })
        assertTrue(h.sent.any { it.contains("\"resync\"") })
        assertFalse(h.session.snapshot.value.solo)

        // The room answers with its state: item 1 has been playing for a while
        h.session.onMessage(twoItemState("playing", epoch = 1, startedAt = h.serverNow() - 4000))
        step(3000)
        assertEquals(item, h.player.loaded, "back on the room's song")
        assertTrue(h.player.playing)
    }

    @Test
    fun `the room pausing while following is reported, but not when this device did it`() = runTest {
        val h = playingFirstOfTwo()
        val seen = mutableListOf<GroupSession.RoomEvent>()
        backgroundScope.launch { h.session.events.collect { seen += it } }
        runCurrent()
        h.session.onMessage(ServerMessage.Pause(epoch = 2, positionMs = 3000, by = "dev-b"))
        step(100)
        assertEquals(listOf<GroupSession.RoomEvent>(GroupSession.RoomEvent.Paused("dev-b")), seen)

        h.session.onMessage(ServerMessage.Start(epoch = 3, startAt = h.serverNow() + 1500, positionMs = 3000, by = "dev-b"))
        step(1600)
        h.session.onMessage(ServerMessage.Pause(epoch = 4, positionMs = 5000, by = "dev-a"))
        step(100)
        assertEquals(1, seen.size, "our own pause is not news")
    }

    @Test
    fun `a skip by someone else is reported with the new title`() = runTest {
        val h = playingFirstOfTwo()
        val seen = mutableListOf<GroupSession.RoomEvent>()
        backgroundScope.launch { h.session.events.collect { seen += it } }
        runCurrent()
        h.session.onMessage(ServerMessage.Prepare(epoch = 2, index = 1, item = item2, seekToMs = 0, by = "dev-b"))
        step(100)
        assertEquals(listOf<GroupSession.RoomEvent>(GroupSession.RoomEvent.Skipped("dev-b", "Song 2")), seen)
    }

    @Test
    fun `after a reconnect the room is told again that this device is alone`() = runTest {
        val h = playingFirstOfTwo()
        h.session.goSolo()
        step(500)
        h.sent.clear()
        h.session.onReconnected()
        step(100)
        assertTrue(h.sent.any { it.contains("\"solo\"") && it.contains("true") })
    }
}
