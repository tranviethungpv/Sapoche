package app.unison.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ListenTrackerTest {

    private val heard = mutableListOf<Pair<String, Long>>()
    private val tracker = ListenTracker { id, durationMs -> heard += id to durationMs }

    @Test
    fun `a song counts after thirty seconds of playing`() {
        tracker.begin("a", 200_000, now = 0)
        tracker.setPlaying(true, now = 0)
        tracker.check(29_999)
        assertEquals(emptyList(), heard)
        tracker.check(30_000)
        assertEquals(listOf("a" to 200_000L), heard)
    }

    @Test
    fun `it counts once however often it is checked`() {
        tracker.begin("a", 200_000, now = 0)
        tracker.setPlaying(true, now = 0)
        tracker.check(31_000)
        tracker.check(90_000)
        tracker.begin(null, 0, now = 100_000)
        assertEquals(1, heard.size)
    }

    @Test
    fun `pauses and buffering do not count`() {
        tracker.begin("a", 200_000, now = 0)
        tracker.setPlaying(true, now = 0)
        tracker.setPlaying(false, now = 20_000)
        tracker.check(500_000) // a long pause
        assertEquals(emptyList(), heard)
        tracker.setPlaying(true, now = 500_000)
        tracker.check(509_999)
        assertEquals(emptyList(), heard)
        tracker.check(510_000)
        assertEquals(1, heard.size)
    }

    @Test
    fun `a song skipped early does not count`() {
        tracker.begin("a", 200_000, now = 0)
        tracker.setPlaying(true, now = 0)
        tracker.begin("b", 180_000, now = 12_000)
        tracker.setPlaying(true, now = 12_000)
        tracker.begin(null, 0, now = 20_000)
        assertEquals(emptyList(), heard)
    }

    @Test
    fun `a song that had just passed the mark when it was skipped still counts`() {
        // The timer for it may not have run yet when the next song was already loading
        tracker.begin("a", 200_000, now = 0)
        tracker.setPlaying(true, now = 0)
        tracker.begin("b", 180_000, now = 30_500)
        assertEquals(listOf("a" to 200_000L), heard)
    }

    @Test
    fun `a short song counts at half its length`() {
        tracker.begin("clip", 20_000, now = 0)
        tracker.setPlaying(true, now = 0)
        tracker.check(9_999)
        assertEquals(emptyList(), heard)
        tracker.check(10_000)
        assertEquals(listOf("clip" to 20_000L), heard)
    }

    @Test
    fun `the length may become known after the song began`() {
        tracker.begin("a", 0, now = 0)
        tracker.setPlaying(true, now = 0)
        assertEquals(30_000L, tracker.msUntilHeard(0))
        tracker.setDuration(40_000)
        assertEquals(20_000L, tracker.msUntilHeard(0))
        tracker.check(20_000)
        assertEquals(listOf("a" to 40_000L), heard)
    }

    @Test
    fun `it says how long to wait, and nothing when there is nothing to wait for`() {
        assertNull(tracker.msUntilHeard(0))
        tracker.begin("a", 200_000, now = 0)
        assertNull(tracker.msUntilHeard(0), "not playing yet")
        tracker.setPlaying(true, now = 1_000)
        assertEquals(30_000L, tracker.msUntilHeard(1_000))
        assertEquals(20_000L, tracker.msUntilHeard(11_000))
        tracker.setPlaying(false, now = 11_000)
        assertNull(tracker.msUntilHeard(11_000))
        tracker.setPlaying(true, now = 50_000)
        assertEquals(20_000L, tracker.msUntilHeard(50_000), "the ten seconds already heard are kept")
        tracker.check(70_000)
        assertNull(tracker.msUntilHeard(70_000), "already counted")
    }

    @Test
    fun `playing with nothing loaded is ignored`() {
        tracker.setPlaying(true, now = 0)
        tracker.check(60_000)
        assertEquals(emptyList(), heard)
    }

    @Test
    fun `the same song again is a new listen`() {
        tracker.begin("a", 200_000, now = 0)
        tracker.setPlaying(true, now = 0)
        tracker.check(30_000)
        tracker.begin("a", 200_000, now = 200_000)
        tracker.setPlaying(true, now = 200_000)
        tracker.check(230_000)
        assertEquals(2, heard.size)
    }

    private val skipped = mutableListOf<String>()
    private val watching = ListenTracker(skipped = { id, _ -> skipped += id }) { id, durationMs -> heard += id to durationMs }

    @Test
    fun `a song left after a few seconds was skipped`() {
        watching.begin("a", 200_000, now = 0)
        watching.setPlaying(true, now = 0)
        watching.begin("b", 200_000, now = 8_000)
        assertEquals(listOf("a"), skipped)
        assertEquals(emptyList(), heard)
    }

    @Test
    fun `a song that was heard is not skipped, and nor is one left at once or never played`() {
        watching.begin("a", 200_000, now = 0)
        watching.setPlaying(true, now = 0)
        watching.begin("b", 200_000, now = 40_000) // heard: more than thirty seconds
        watching.setPlaying(true, now = 40_000)
        watching.begin("c", 200_000, now = 41_000) // a second is a glitch
        watching.begin("d", 200_000, now = 100_000) // c was never playing
        watching.begin(null, 0, now = 101_000) // d was never playing either
        assertEquals(emptyList(), skipped)
    }

    @Test
    fun `pauses do not make a song longer when it is left`() {
        watching.begin("a", 200_000, now = 0)
        watching.setPlaying(true, now = 0)
        watching.setPlaying(false, now = 2_000)
        watching.begin("b", 200_000, now = 600_000)
        assertEquals(emptyList(), skipped, "two seconds of playing is a glitch, however long it sat paused")
    }
}
