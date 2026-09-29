package app.unison.sync

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.io.File
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class LocalSessionTest {

    private fun track(n: Int) = TrackRef("video$n".padEnd(11, 'x').take(11), "Song $n", "Artist", null, 200_000)

    private class Harness(scope: TestScope, saved: SavedQueue?) {
        val now: () -> Long = { scope.currentTime }
        val player = FakePlayer(now)
        val saved = mutableListOf<SavedQueue>()
        val problems = mutableListOf<String>()
        private var counter = 0
        val session = LocalSession(
            scope.backgroundScope,
            player,
            saved,
            persist = { this.saved += it },
            problem = { problems += it },
            newId = { "id${++counter}" },
            random = Random(7),
        ).also { it.attach() }
    }

    private fun TestScope.harness(saved: SavedQueue? = null) = Harness(this, saved)

    private fun TestScope.step(ms: Long = 100) {
        advanceTimeBy(ms)
        runCurrent()
    }

    private fun Harness.titles() = session.snapshot.value.queue.map { it.title }

    @Test
    fun `adding to an empty queue starts playing the first song`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        assertEquals("Song 1", h.player.loaded?.title)
        assertTrue(h.player.playing)
        assertEquals(listOf("Song 1", "Song 2"), h.titles())
        assertEquals("Song 2", h.player.queuedNext?.title, "the next song is ready for a gapless finish")
    }

    @Test
    fun `adding while playing does not disturb it`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        val loads = h.player.prepareCount
        h.session.add(listOf(track(2), track(3)), next = false)
        step()
        assertEquals(loads, h.player.prepareCount)
        assertEquals("Song 2", h.player.queuedNext?.title)
        assertEquals(3, h.session.snapshot.value.queue.size)
    }

    @Test
    fun `play next goes right after the current song`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.add(listOf(track(3)), next = true)
        step()
        assertEquals(listOf("Song 1", "Song 3", "Song 2"), h.titles())
        assertEquals("Song 3", h.player.queuedNext?.title)
    }

    @Test
    fun `next moves along and the last song ends the queue`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.next()
        step()
        assertEquals("Song 2", h.player.loaded?.title)
        assertEquals(1, h.session.snapshot.value.index)
        h.player.onEnded?.invoke()
        step()
        assertFalse(h.player.playing)
        assertNull(h.player.loaded, "the player is let go of")
        assertTrue(h.session.snapshot.value.finished)
    }

    @Test
    fun `play after the queue finished starts it again from the top`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.next()
        step()
        h.player.onEnded?.invoke()
        step()
        h.session.play()
        step()
        assertEquals("Song 1", h.player.loaded?.title)
        assertTrue(h.player.playing)
        assertFalse(h.session.snapshot.value.finished)
    }

    @Test
    fun `repeat all wraps around and repeat one plays the same song again`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.setRepeat("all")
        h.session.next()
        step()
        h.player.onEnded?.invoke()
        step()
        assertEquals("Song 1", h.player.loaded?.title)

        h.session.setRepeat("one")
        step()
        assertNull(h.player.queuedNext, "repeating one song has no successor, or the player would move on by itself")
        val loads = h.player.prepareCount
        h.player.onEnded?.invoke()
        step()
        assertEquals("Song 1", h.player.loaded?.title)
        assertEquals(loads + 1, h.player.prepareCount)
    }

    @Test
    fun `the player moving on by itself is followed and the next song is prepared`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2), track(3)), next = false)
        step()
        h.player.autoAdvance()
        step()
        assertEquals(1, h.session.snapshot.value.index)
        assertEquals("Song 3", h.player.queuedNext?.title)
    }

    @Test
    fun `previous restarts a song that has played a while and goes back when it has just begun`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.next()
        step(10_000)
        h.session.prev()
        step()
        assertEquals(1, h.session.snapshot.value.index, "still on the second song")
        assertTrue(h.player.position < 1000, "and back at its start")
        h.session.prev()
        step()
        assertEquals(0, h.session.snapshot.value.index)
    }

    @Test
    fun `removing the current song plays the one after it`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2), track(3)), next = false)
        step()
        h.session.remove("id1")
        step()
        assertEquals("Song 2", h.player.loaded?.title)
        assertTrue(h.player.playing)
        assertEquals(listOf("Song 2", "Song 3"), h.titles())
        assertEquals(0, h.session.snapshot.value.index)
    }

    @Test
    fun `removing an earlier song keeps the current one`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2), track(3)), next = false)
        step()
        h.session.next()
        step()
        h.session.remove("id1")
        step()
        assertEquals("Song 2", h.session.snapshot.value.current?.title)
        assertEquals(0, h.session.snapshot.value.index)
        assertTrue(h.player.playing)
    }

    @Test
    fun `removing the only or the last song stops cleanly`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.next()
        step()
        h.session.remove("id2")
        step()
        assertTrue(h.session.snapshot.value.finished)
        assertNull(h.player.loaded)
        h.session.remove("id1")
        step()
        assertEquals(emptyList(), h.titles())
        assertFalse(h.session.snapshot.value.finished)
    }

    @Test
    fun `moving a song keeps the current one current`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2), track(3)), next = false)
        step()
        h.session.move("id3", 0)
        step()
        assertEquals(listOf("Song 3", "Song 1", "Song 2"), h.titles())
        assertEquals(1, h.session.snapshot.value.index)
        assertEquals("Song 1", h.session.snapshot.value.current?.title)
        assertTrue(h.player.playing)
    }

    @Test
    fun `shuffle mixes only what is to come`() = runTest {
        val h = harness()
        h.session.add((1..8).map(::track), next = false)
        step()
        h.session.next()
        step()
        val before = h.titles()
        h.session.shuffle()
        step()
        val after = h.titles()
        assertEquals(before.take(2), after.take(2), "what was played and the current song stay put")
        assertEquals(before.drop(2).toSet(), after.drop(2).toSet())
        assertTrue(before != after, "the rest was mixed")
        assertEquals(after[2], h.player.queuedNext?.title, "and the successor follows the new order")
    }

    @Test
    fun `shuffle after the queue finished mixes everything and plays from the top`() = runTest {
        val h = harness()
        h.session.add((1..6).map(::track), next = false)
        step()
        h.session.setRepeat("off")
        repeat(6) {
            h.player.onEnded?.invoke()
            step()
        }
        assertTrue(h.session.snapshot.value.finished)
        h.session.shuffle()
        step()
        assertFalse(h.session.snapshot.value.finished)
        assertEquals(0, h.session.snapshot.value.index)
        assertTrue(h.player.playing)
    }

    @Test
    fun `jump plays the chosen song`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2), track(3)), next = false)
        step()
        h.session.jump("id3")
        step()
        assertEquals("Song 3", h.player.loaded?.title)
        assertEquals(2, h.session.snapshot.value.index)
    }

    @Test
    fun `clear empties the queue and silences the player`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.clear()
        step()
        assertEquals(emptyList(), h.titles())
        assertFalse(h.player.playing)
        assertNull(h.player.loaded)
    }

    @Test
    fun `a restored queue loads nothing and plays nothing until asked`() = runTest {
        val song = QueueItem("a", "aaaaaaaaaaa", "One", "x", null, 200_000, "")
        val other = QueueItem("b", "bbbbbbbbbbb", "Two", "x", null, 200_000, "")
        val h = harness(SavedQueue(listOf(song, other), index = 1, repeat = "all", positionMs = 42_000))
        step()
        assertNull(h.player.loaded)
        assertFalse(h.player.playing)
        assertEquals("Two", h.session.snapshot.value.current?.title)
        assertEquals("all", h.session.snapshot.value.repeat)
        assertEquals(42_000L, h.session.restoredPositionMs)

        h.session.play()
        step()
        assertEquals(other, h.player.loaded)
        assertTrue(h.player.playing)
        assertTrue(h.player.position >= 42_000, "resumes where it was left, was ${h.player.position}")
        assertNull(h.session.restoredPositionMs)
    }

    @Test
    fun `a saved queue with a bad index or repeat is put right`() = runTest {
        val song = QueueItem("a", "aaaaaaaaaaa", "One", "x", null, 200_000, "")
        val h = harness(SavedQueue(listOf(song), index = 9, repeat = "sideways"))
        assertEquals(0, h.session.snapshot.value.index)
        assertEquals("off", h.session.snapshot.value.repeat)
    }

    @Test
    fun `changes and pauses are saved with the position`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step(5000)
        h.session.pause()
        val saved = h.saved.last()
        assertEquals(listOf("Song 1", "Song 2"), saved.queue.map { it.title })
        assertEquals(0, saved.index)
        assertTrue(saved.positionMs in 4000..6000, "position was ${saved.positionMs}")
    }

    @Test
    fun `a room taking over silences the player and coming back resumes where it was`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step(8000)
        h.session.detach()
        assertFalse(h.player.playing)
        assertNull(h.player.loaded)
        val position = h.saved.last().positionMs
        assertTrue(position in 7000..9000)

        h.session.attach()
        h.session.play()
        step()
        assertEquals("Song 1", h.player.loaded?.title)
        assertTrue(h.player.position >= position)
    }

    @Test
    fun `a stream that breaks is loaded again where it stopped`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step(9000)
        val loads = h.player.prepareCount
        h.player.onError?.invoke(RuntimeException("403"))
        step()
        assertEquals(loads + 1, h.player.prepareCount)
        assertEquals("Song 1", h.player.loaded?.title)
        assertTrue(h.player.position >= 9000, "was ${h.player.position}")
        assertTrue(h.player.playing)
    }

    @Test
    fun `a stream that keeps breaking is given up on and the next song plays`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step(1000)
        repeat(3) {
            h.player.onError?.invoke(RuntimeException("403"))
            step()
        }
        assertEquals("Song 1", h.player.loaded?.title)
        h.player.onError?.invoke(RuntimeException("403"))
        step()
        assertEquals("Song 2", h.player.loaded?.title)
        assertTrue(h.problems.any { it.contains("Song 1") })
    }

    @Test
    fun `asking to play twice while the song is loading loads it once`() = runTest {
        val song = QueueItem("a", "aaaaaaaaaaa", "One", "x", null, 200_000, "")
        val h = harness(SavedQueue(listOf(song)))
        h.player.prepareDelayMs = 2000
        h.session.play()
        step(500)
        h.session.play()
        // Two seconds after the first press: a restart at the second press would still be loading
        step(1700)
        assertTrue(h.player.playing, "the second press must not cancel and restart the load")
        assertEquals(1, h.player.prepareCount)
    }

    @Test
    fun `pausing while the song is loading leaves it paused when it is ready`() = runTest {
        val song = QueueItem("a", "aaaaaaaaaaa", "One", "x", null, 200_000, "")
        val h = harness(SavedQueue(listOf(song)))
        h.player.prepareDelayMs = 2000
        h.session.play()
        step(500)
        h.session.pause()
        step(3000)
        assertEquals(song, h.player.loaded)
        assertFalse(h.player.playing)
        h.session.play()
        step(100)
        assertTrue(h.player.playing)
    }

    @Test
    fun `a song that cannot be loaded is reported and leaves nothing playing`() = runTest {
        val h = harness()
        h.player.failPrepare = true
        h.session.add(listOf(track(1)), next = false)
        step()
        assertTrue(h.problems.any { it.contains("Song 1") })
        assertFalse(h.player.playing)
        assertEquals("Song 1", h.session.snapshot.value.current?.title, "it stays in the queue to try again")
    }

    @Test
    fun `the queue is capped like the room's`() = runTest {
        val h = harness()
        h.session.add((1..150).map(::track), next = false)
        step()
        h.session.add((151..300).map(::track), next = false)
        step()
        assertEquals(200, h.session.snapshot.value.queue.size)
        h.session.add(listOf(track(301)), next = false)
        assertTrue(h.problems.any { it.contains("full") })
    }

    @Test
    fun `the queue survives a round trip through its file`() {
        val file = File.createTempFile("queue", ".json")
        try {
            val queueFile = QueueFile(file)
            val saved = SavedQueue(
                listOf(QueueItem("a", "aaaaaaaaaaa", "One", "x", "https://i/x.jpg", 1000, "")),
                index = 0,
                repeat = "one",
                positionMs = 123,
                finished = true,
            )
            queueFile.write(saved)
            assertEquals(saved, queueFile.read())
            file.writeText("{ not json")
            assertNull(queueFile.read(), "a damaged file means an empty queue, not a crash")
        } finally {
            file.delete()
            File(file.path + ".tmp").delete()
        }
    }
}
