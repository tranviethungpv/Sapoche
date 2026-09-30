package app.unison.sync

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class SleepTimerTest {

    private val scope = TestScope()
    private val calls = mutableListOf<String>()
    private val volumes = mutableListOf<Float>()
    private var atSongEnd = false
    private val timer = SleepTimer(
        scope,
        wallClock = { 1_000_000L + scope.testScheduler.currentTime },
        stop = { calls += "stop" },
        fade = { volumes += it },
        pauseAtSongEnd = { atSongEnd = it },
    )

    private fun pass(ms: Long) {
        scope.advanceTimeBy(ms)
        scope.runCurrent()
    }

    @Test
    fun `it stops when the time is up and not before`() {
        timer.startIn(10)
        assertEquals(Sleep.At(1_000_000L + 600_000L), timer.state.value)
        pass(599_999)
        assertEquals(emptyList(), calls)
        pass(1)
        assertEquals(listOf("stop"), calls)
        assertEquals(Sleep.Off, timer.state.value)
    }

    @Test
    fun `the volume goes down over the last seconds and comes back after the stop`() {
        timer.startIn(1)
        volumes.clear()
        pass(44_000)
        assertEquals(emptyList(), volumes) // full volume until the fade starts
        pass(1_000) // the fade starts at 45 s
        assertEquals(1f, volumes.first())
        pass(15_000)
        assertEquals(listOf("stop"), calls)
        assertTrue(volumes.dropLast(1).zipWithNext().all { (a, b) -> b <= a }, "$volumes")
        assertEquals(1f, volumes.last())
        assertTrue(volumes.min() < 0.1f, "$volumes")
    }

    @Test
    fun `cancelling stops nothing and gives the volume back`() {
        timer.startIn(5)
        pass(290_000) // in the fade
        timer.cancel()
        volumes.clear()
        pass(600_000)
        assertEquals(emptyList(), calls)
        assertEquals(Sleep.Off, timer.state.value)
        assertEquals(emptyList(), volumes)
    }

    @Test
    fun `a new setting replaces the old one`() {
        timer.startIn(5)
        pass(240_000)
        timer.startIn(30)
        pass(600_000)
        assertEquals(emptyList(), calls)
        pass(1_200_000)
        assertEquals(listOf("stop"), calls)
    }

    @Test
    fun `at the end of the song it asks the player to pause there and stops when told it did`() {
        timer.startAtSongEnd()
        assertTrue(atSongEnd)
        assertEquals(Sleep.SongEnd, timer.state.value)
        pass(3_600_000) // time does not matter
        assertEquals(emptyList(), calls)
        timer.songEnded()
        assertEquals(listOf("stop"), calls)
        assertEquals(Sleep.Off, timer.state.value)
        assertEquals(false, atSongEnd)
    }

    @Test
    fun `a song ending means nothing to a timer set in minutes`() {
        timer.startIn(10)
        timer.songEnded()
        assertEquals(emptyList(), calls)
        assertEquals(Sleep.At(1_000_000L + 600_000L), timer.state.value)
    }

    @Test
    fun `turning it off after choosing the song end lets the player carry on`() {
        timer.startAtSongEnd()
        timer.cancel()
        assertEquals(false, atSongEnd)
        timer.songEnded()
        assertEquals(emptyList(), calls)
    }
}
