package app.sapoche.sync

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
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
        val ended = mutableListOf<String>()
        val now: () -> Long = { scope.currentTime }
        val player = FakePlayer(now)
        val saved = mutableListOf<SavedQueue>()
        val problems = mutableListOf<LocalSession.Problem>()
        private var counter = 0
        val session = LocalSession(
            scope.backgroundScope,
            player,
            saved,
            persist = { this.saved += it },
            problem = { problems += it },
            onQueueEnd = { ended += it.title },
            newId = { "id${++counter}" },
            random = Random(7),
            nowMs = now,
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
    fun `a stall while listening alone makes the network weak, and a quiet spell makes it good again`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        step(2_000)
        assertFalse(h.session.health.weak)

        h.player.buffering = true
        h.player.playing = false
        step(3_000)
        h.player.buffering = false
        h.player.playing = true
        step(1_000)
        assertTrue(h.session.health.weak, "stalled for seconds, then played again")

        step(NetworkHealth.QUIET_MS + 2_000)
        assertFalse(h.session.health.weak, "a minute without a stall, and the buffer is full")
    }

    @Test
    fun `a pause someone asked for is not a stall`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        h.session.pause()
        step(5_000)
        h.session.play()
        step(2_000)
        assertFalse(h.session.health.weak)
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
    fun `playing a list from a song keeps the songs before it to go back to`() = runTest {
        val h = harness()
        h.session.add(listOf(track(9)), next = false)
        step()
        h.session.playList((1..5).map(::track), start = 2)
        step()
        assertEquals(listOf("Song 1", "Song 2", "Song 3", "Song 4", "Song 5"), h.titles(), "the old queue is gone")
        assertEquals(2, h.session.snapshot.value.index)
        assertEquals("Song 3", h.player.loaded?.title)
        assertTrue(h.player.playing)
        assertEquals("Song 4", h.player.queuedNext?.title)
        h.session.next()
        h.session.prev()
        step()
        assertEquals("Song 3", h.player.loaded?.title)
        h.session.prev()
        step()
        assertEquals("Song 2", h.player.loaded?.title, "back goes to the song before the one chosen")
    }

    @Test
    fun `a list played from a start outside it is kept inside`() = runTest {
        val h = harness()
        h.session.playList((1..3).map(::track), start = 9)
        step()
        assertEquals("Song 3", h.player.loaded?.title)
        h.session.playList((1..3).map(::track), start = -4)
        step()
        assertEquals("Song 1", h.player.loaded?.title)
        h.session.playList(emptyList(), start = 0)
        assertEquals(3, h.session.snapshot.value.queue.size, "nothing to play changes nothing")
    }

    @Test
    fun `playing a list with shuffle on starts at the song and mixes the rest`() = runTest {
        val h = harness()
        h.session.setShuffle(true)
        h.session.playList((1..8).map(::track), start = 3)
        step()
        val s = h.session.snapshot.value
        assertEquals(0, s.index)
        assertEquals("Song 4", s.current?.title)
        assertEquals("Song 4", h.player.loaded?.title)
        assertEquals((1..8).map { "Song $it" }.toSet(), h.titles().toSet())
        assertEquals(8, s.queue.size)
        h.session.setShuffle(false)
        assertEquals(listOf("Song 4") + listOf(1, 2, 3, 5, 6, 7, 8).map { "Song $it" }, h.titles(), "off puts the rest back in the list's order")
    }

    @Test
    fun `the end of a list played from the middle wraps to its first song when repeating all`() = runTest {
        val h = harness()
        h.session.setRepeat("all")
        h.session.playList((1..3).map(::track), start = 1)
        step()
        h.session.next()
        step()
        assertEquals("Song 3", h.player.loaded?.title)
        h.session.next()
        step()
        assertEquals("Song 1", h.player.loaded?.title)
    }

    @Test
    fun `a song already waiting in the queue is not added again`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        h.session.add(listOf(track(2)), next = false)
        h.session.add(listOf(track(2), track(3), track(3)), next = false)
        step()
        assertEquals(listOf("Song 1", "Song 2", "Song 3"), h.titles())
        assertTrue(h.problems.isEmpty())
    }

    @Test
    fun `a song that was played can be added again`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.next()
        step()
        h.session.add(listOf(track(1)), next = false)
        step()
        assertEquals(listOf("Song 1", "Song 2", "Song 1"), h.titles())
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
    fun `the queue running out is announced with the last song, once`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.next()
        step()
        assertEquals(emptyList(), h.ended, "a song is still to come")
        h.session.next()
        step()
        assertEquals(listOf("Song 2"), h.ended)
    }

    @Test
    fun `an end reported while nothing of ours is loaded changes nothing`() = runTest {
        // What a restarted service's player says when it has nothing to play
        val h = harness(SavedQueue(listOf(QueueItem("q1", "video1xxxxx", "Song 1", "Artist", null, 200_000, "")), 0, "off", 30_000, false))
        h.player.onEnded?.invoke()
        step()
        assertFalse(h.session.snapshot.value.finished)
        assertEquals(emptyList(), h.ended)
        assertEquals(30_000L, h.session.restoredPositionMs, "it still resumes where it was")
    }

    @Test
    fun `a song ending by itself at the end of the queue is announced`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        h.player.onEnded?.invoke()
        step()
        assertEquals(listOf("Song 1"), h.ended)
    }

    @Test
    fun `repeating or removing the last song does not announce an end`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        h.session.setRepeat("all")
        h.player.onEnded?.invoke()
        step()
        assertEquals(emptyList(), h.ended, "repeat all starts over")
        h.session.setRepeat("off")
        h.session.remove(h.session.snapshot.value.queue.last().id)
        step()
        assertEquals(emptyList(), h.ended, "the person took it away")
    }

    @Test
    fun `songs added after the end start playing`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        h.session.next()
        step()
        assertTrue(h.session.snapshot.value.finished)
        h.session.add(listOf(track(2), track(3)), next = false)
        step()
        assertEquals("Song 2", h.player.loaded?.title)
        assertTrue(h.player.playing)
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
    fun `swapping the song that plays loads the other release from the same moment`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        step(5_000)
        val before = h.player.position
        h.session.swap("id1", TrackRef("videoSwappd", "Song 1 (Video)", "Artist", null, 210_000))
        step()
        assertEquals("videoSwappd", h.player.loaded?.videoId)
        assertEquals("id1", h.player.loaded?.id, "the same place in the queue")
        assertTrue(h.player.position >= before, "from where it was, not from the start")
        assertTrue(h.player.playing, "still playing")
        assertEquals(listOf("Song 1 (Video)", "Song 2"), h.titles())
        assertEquals("Song 2", h.player.queuedNext?.title)
    }

    @Test
    fun `swapping a song that is buffering still plays the other release`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        h.player.playing = false // rebuffering: not heard, but not paused by anybody
        h.session.swap("id1", TrackRef("videoSwappd", "Song 1 (Video)", "Artist", null, 210_000))
        step()
        assertEquals("videoSwappd", h.player.loaded?.videoId)
        assertTrue(h.player.playing)
    }

    @Test
    fun `swapping a song that is paused keeps it paused`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        h.session.pause()
        step()
        h.session.swap("id1", TrackRef("videoSwappd", "Song 1 (Video)", "Artist", null, 210_000))
        step()
        assertEquals("videoSwappd", h.player.loaded?.videoId)
        assertFalse(h.player.playing)
    }

    @Test
    fun `swapping a song still to come changes it quietly`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        val loads = h.player.prepareCount
        h.session.swap("id2", TrackRef("videoSwappd", "Song 2 (Video)", "Artist", null, 210_000))
        step()
        assertEquals(loads, h.player.prepareCount, "what plays is not touched")
        assertEquals("videoSwappd", h.player.queuedNext?.videoId, "and the next one is the other release")
        assertEquals(listOf("Song 1", "Song 2 (Video)"), h.titles())
    }

    @Test
    fun `swapping for the same release or an unknown song does nothing`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        val loads = h.player.prepareCount
        h.session.swap("id1", track(1))
        h.session.swap("nope", track(5))
        step()
        assertEquals(loads, h.player.prepareCount)
        assertEquals(listOf("Song 1"), h.titles())
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
    fun `shuffle as a mode mixes what is to come, and off puts it back in order`() = runTest {
        val h = harness()
        h.session.add((1..8).map(::track), next = false)
        step()
        h.session.next()
        step()
        val before = h.titles()
        h.session.setShuffle(true)
        step()
        assertTrue(h.session.snapshot.value.shuffle)
        val mixed = h.titles()
        assertEquals(before.take(2), mixed.take(2), "what was played and the current song stay put")
        assertEquals(before.drop(2).toSet(), mixed.drop(2).toSet())
        assertTrue(before != mixed, "the rest was mixed")
        assertEquals(mixed[2], h.player.queuedNext?.title, "and the successor follows the new order")

        h.session.setShuffle(false)
        step()
        assertFalse(h.session.snapshot.value.shuffle)
        assertEquals(before, h.titles(), "turning it off puts the songs back in the order they had")
    }

    @Test
    fun `songs added while shuffle is on keep their order ahead of the shuffled list`() = runTest {
        val h = harness()
        h.session.add((1..6).map(::track), next = false)
        step()
        h.session.setShuffle(true)
        step()
        h.session.add(listOf(track(7)), next = false)
        h.session.add(listOf(track(8)), next = true)
        step()
        val titles = h.titles()
        assertEquals(listOf("Song 1", "Song 8", "Song 7"), titles.take(3), "queued songs stay in order right after the current song")

        h.session.setShuffle(false)
        step()
        assertEquals(listOf("Song 1", "Song 8", "Song 7", "Song 2", "Song 3", "Song 4", "Song 5", "Song 6"), h.titles())
    }

    @Test
    fun `shuffle mode survives clearing the queue and is saved`() = runTest {
        val h = harness()
        h.session.add((1..4).map(::track), next = false)
        step()
        h.session.setShuffle(true)
        step()
        h.session.clear()
        step()
        assertTrue(h.session.snapshot.value.shuffle, "clearing the queue leaves the mode as it was")
        assertTrue(h.saved.last().shuffle)
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
    fun `dropping played songs keeps the one playing and those to come`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2), track(3), track(4)), next = false)
        step()
        h.session.jump(h.session.snapshot.value.queue[2].id)
        step()
        h.session.dropPlayed(10)
        step()
        assertEquals(listOf("Song 3", "Song 4"), h.titles())
        assertEquals(0, h.session.snapshot.value.index)
        assertEquals("Song 3", h.player.loaded?.title)
    }

    @Test
    fun `once the queue has finished all of it may be dropped, oldest first`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2), track(3)), next = false)
        step()
        h.session.jump(h.session.snapshot.value.queue[2].id)
        step()
        h.player.onEnded?.invoke()
        step()
        assertTrue(h.session.snapshot.value.finished)
        h.session.dropPlayed(2)
        step()
        assertEquals(listOf("Song 3"), h.titles())
        assertEquals(0, h.session.snapshot.value.index)
        h.session.dropPlayed(0)
        h.session.dropPlayed(-5)
        assertEquals(listOf("Song 3"), h.titles())
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
        assertEquals(
            listOf(LocalSession.Problem(LocalSession.Problem.Kind.BROKEN, "Song 1")),
            h.problems.filter { it.title == "Song 1" },
            "a stream that keeps breaking is told as the connection's doing, not as a song YouTube will not give out",
        )
    }

    @Test
    fun `a new song in the place of one that broke gets all its tries`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step(1000)
        h.player.onError?.invoke(RuntimeException("403"))
        step()
        // A new list starts where the old one was, at the top of the queue
        h.session.clear()
        h.session.add(listOf(track(2)), next = false)
        step(1000)
        repeat(3) {
            h.player.onError?.invoke(RuntimeException("403"))
            step()
        }
        assertEquals("Song 2", h.player.loaded?.title)
        assertFalse(h.problems.any { it.title == "Song 2" }, "the tries of Song 1 are not counted for it")
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
        step(LocalSession.RETRY_AFTER_MS + 500)
        assertTrue(h.problems.any { it.title == "Song 1" })
        assertFalse(h.player.playing)
        assertEquals("Song 1", h.session.snapshot.value.current?.title, "it stays in the queue to try again")
    }

    @Test
    fun `a song is shown as on its way until it plays`() = runTest {
        val h = harness()
        h.player.prepareDelayMs = 3000
        h.session.add(listOf(track(1)), next = false)
        step(1000)
        assertTrue(h.session.snapshot.value.loading, "the screen must show something is happening")
        assertFalse(h.player.playing)
        step(2500)
        assertFalse(h.session.snapshot.value.loading)
        assertTrue(h.player.playing)
    }

    @Test
    fun `pausing while a song loads no longer shows it as on its way`() = runTest {
        val h = harness()
        h.player.prepareDelayMs = 3000
        h.session.add(listOf(track(1)), next = false)
        step(1000)
        h.session.pause()
        assertFalse(h.session.snapshot.value.loading)
        h.session.play()
        assertTrue(h.session.snapshot.value.loading)
    }

    @Test
    fun `a slow load is said to be slow, once`() = runTest {
        val h = harness()
        h.player.prepareDelayMs = 20_000
        h.session.add(listOf(track(1)), next = false)
        step(7000)
        assertTrue(h.problems.isEmpty(), "not slow yet")
        step(2000)
        assertEquals(listOf(LocalSession.Problem(LocalSession.Problem.Kind.SLOW, "Song 1")), h.problems)
        step(15_000)
        assertTrue(h.player.playing)
        assertEquals(1, h.problems.size)
    }

    @Test
    fun `trying a slow song again starts from a new stream address`() = runTest {
        val h = harness()
        h.player.prepareDelayMs = 20_000
        h.session.add(listOf(track(1), track(2)), next = false)
        step(9000)
        assertEquals(1, h.problems.size, "said to be slow")
        assertTrue(h.player.refreshed.isEmpty(), "waiting alone keeps the address")
        h.session.jump(h.session.snapshot.value.queue[0].id)
        step()
        assertEquals(listOf(track(1).videoId), h.player.refreshed)
    }

    @Test
    fun `a song tapped again after a failure starts from a new stream address, also from a new queue`() = runTest {
        val h = harness()
        h.player.failPrepare = true
        h.session.add(listOf(track(1)), next = false)
        step(LocalSession.RETRY_AFTER_MS + 500)
        assertEquals(LocalSession.Problem.Kind.FAILED, h.problems.single().kind)
        h.player.failPrepare = false
        h.player.refreshed.clear()
        h.session.clear()
        h.session.add(listOf(track(1)), next = false) // the list was tapped: the same song with another queue id
        step()
        assertEquals(listOf(track(1).videoId), h.player.refreshed)
        assertTrue(h.player.playing)

        // It played: the next time is an ordinary load
        h.session.add(listOf(track(2)), next = false)
        h.session.jump(h.session.snapshot.value.queue[1].id)
        h.session.jump(h.session.snapshot.value.queue[0].id)
        step()
        assertEquals(1, h.player.refreshed.size)
    }

    @Test
    fun `a load that ends quickly or is replaced is not called slow`() = runTest {
        val h = harness()
        h.player.prepareDelayMs = 5000
        h.session.add(listOf(track(1), track(2)), next = false)
        step(4000)
        h.session.next() // the first load is dropped before it gets slow
        step(10_000)
        assertTrue(h.problems.isEmpty(), "was ${h.problems}")
        assertEquals("Song 2", h.player.loaded?.title)
    }

    @Test
    fun `a song YouTube will not play is skipped and the person told`() = runTest {
        val h = harness()
        h.player.failWith = { if (it.title == "Song 1") LoadFailure(LoadFailure.Reason.UNPLAYABLE, "removed") else null }
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        assertEquals("Song 2", h.player.loaded?.title)
        assertTrue(h.player.playing)
        assertEquals(listOf(LocalSession.Problem(LocalSession.Problem.Kind.SKIPPED, "Song 1")), h.problems)
    }

    @Test
    fun `skipping stops after a few songs in a row that will not play`() = runTest {
        val h = harness()
        h.player.failWith = { LoadFailure(LoadFailure.Reason.UNPLAYABLE, "YouTube changed") }
        h.session.add((1..6).map(::track), next = false)
        step()
        assertEquals(
            listOf(LocalSession.Problem.Kind.SKIPPED, LocalSession.Problem.Kind.SKIPPED, LocalSession.Problem.Kind.UNPLAYABLE),
            h.problems.map { it.kind },
        )
        assertEquals("Song 3", h.session.snapshot.value.current?.title, "it stops instead of running through the queue")
        assertFalse(h.player.playing)
        assertFalse(h.session.snapshot.value.loading)
    }

    @Test
    fun `without a network the song is kept, nothing loads on, and play tries again`() = runTest {
        val h = harness()
        h.player.failWith = { LoadFailure(LoadFailure.Reason.OFFLINE, "no network") }
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        assertEquals(listOf(LocalSession.Problem(LocalSession.Problem.Kind.OFFLINE, "Song 1")), h.problems)
        assertEquals("Song 1", h.session.snapshot.value.current?.title, "not skipped: the next song would fail as well")
        assertNull(h.player.loaded, "the player was stopped, so nothing starts by itself later")
        assertFalse(h.session.snapshot.value.loading)

        h.player.failWith = null
        h.session.play()
        step()
        assertEquals("Song 1", h.player.loaded?.title)
        assertTrue(h.player.playing)
    }

    @Test
    fun `any other failure to load says so and keeps the song when there is nothing to go on to`() = runTest {
        val h = harness()
        h.player.failPrepare = true
        h.session.add(listOf(track(1)), next = false)
        step(LocalSession.RETRY_AFTER_MS + 500)
        assertEquals(listOf(LocalSession.Problem(LocalSession.Problem.Kind.FAILED, "Song 1")), h.problems)
        assertEquals("Song 1", h.session.snapshot.value.current?.title)
        assertTrue(h.ended.isEmpty(), "a failure to load is not the end of the queue, which would start autoplay")
        assertFalse(h.session.snapshot.value.loading)
    }

    /** Fails the first [times] tries of a song, then loads it. */
    private fun Harness.failFirst(times: Int, reason: LoadFailure.Reason? = null) {
        var left = times
        player.failWith = {
            if (left > 0) {
                left--
                if (reason == null) java.io.IOException("blip") else LoadFailure(reason, "x")
            } else {
                null
            }
        }
    }

    @Test
    fun `a song that did not load gets one more try from a new address, and plays if that works`() = runTest {
        val h = harness()
        h.failFirst(1)
        h.session.add(listOf(track(1), track(2)), next = false)
        step(500)
        assertNull(h.player.loaded)
        assertTrue(h.session.snapshot.value.loading, "it shows that something is going on while it waits")
        assertTrue(h.problems.isEmpty(), "a blip is not said to the person")
        step(LocalSession.RETRY_AFTER_MS)
        assertEquals("Song 1", h.player.loaded?.title)
        assertTrue(h.player.playing)
        assertEquals(listOf(track(1).videoId), h.player.refreshed, "the second try starts from a new stream address")
        assertTrue(h.problems.isEmpty())
        assertEquals(2, h.player.prepareAttempts)
    }

    @Test
    fun `a song that fails twice is skipped to the next, which is not what the person wanted to be stopped by`() = runTest {
        val h = harness()
        h.player.failWith = { if (it.title == "Song 1") java.io.IOException("blip") else null }
        h.session.add(listOf(track(1), track(2)), next = false)
        step(LocalSession.RETRY_AFTER_MS + 500)
        assertEquals("Song 2", h.player.loaded?.title)
        assertTrue(h.player.playing)
        assertEquals(listOf(LocalSession.Problem(LocalSession.Problem.Kind.BROKEN, "Song 1")), h.problems)
    }

    @Test
    fun `skipping because songs fail to load stops after a few in a row, with the failure said`() = runTest {
        val h = harness()
        h.player.failWith = { java.io.IOException("the network is a mess") }
        h.session.add((1..6).map(::track), next = false)
        step((LocalSession.RETRY_AFTER_MS + 500) * 4)
        assertEquals(
            listOf(LocalSession.Problem.Kind.BROKEN, LocalSession.Problem.Kind.BROKEN, LocalSession.Problem.Kind.FAILED),
            h.problems.map { it.kind },
        )
        assertEquals("Song 3", h.session.snapshot.value.current?.title)
        assertFalse(h.player.playing)
        assertFalse(h.session.snapshot.value.loading)
        assertEquals(6, h.player.prepareAttempts, "two tries for each of three songs, and no more")
    }

    @Test
    fun `songs that will not play and songs that did not load count together towards stopping`() = runTest {
        val h = harness()
        h.player.failWith = {
            if (it.title == "Song 2") java.io.IOException("blip") else LoadFailure(LoadFailure.Reason.UNPLAYABLE, "gone")
        }
        h.session.add((1..6).map(::track), next = false)
        step((LocalSession.RETRY_AFTER_MS + 500) * 2)
        assertEquals(
            listOf(LocalSession.Problem.Kind.SKIPPED, LocalSession.Problem.Kind.BROKEN, LocalSession.Problem.Kind.UNPLAYABLE),
            h.problems.map { it.kind },
        )
        assertEquals("Song 3", h.session.snapshot.value.current?.title)
    }

    @Test
    fun `the last song of the list is not skipped when it fails, so that no queue ends because of a network`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.failFirst(2)
        h.session.next()
        step(LocalSession.RETRY_AFTER_MS + 500)
        assertEquals(LocalSession.Problem.Kind.FAILED, h.problems.last().kind)
        assertEquals("Song 2", h.session.snapshot.value.current?.title)
        assertFalse(h.session.snapshot.value.finished)
        assertTrue(h.ended.isEmpty())
    }

    @Test
    fun `repeating all with a single song that fails does not loop through it`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1)), next = false)
        step()
        h.session.setRepeat("all")
        h.failFirst(2)
        h.session.jump(h.session.snapshot.value.queue[0].id)
        step(LocalSession.RETRY_AFTER_MS + 500)
        assertEquals(LocalSession.Problem.Kind.FAILED, h.problems.last().kind)
        assertEquals(2, h.player.prepareAttempts - 1, "two tries, and no looping round to the same song")
    }

    @Test
    fun `repeating all goes round to the first song when the last fails`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step()
        h.session.setRepeat("all")
        h.player.failWith = { if (it.title == "Song 2") java.io.IOException("blip") else null }
        h.session.next()
        step(LocalSession.RETRY_AFTER_MS + 500)
        assertEquals("Song 1", h.player.loaded?.title)
        assertEquals(LocalSession.Problem.Kind.BROKEN, h.problems.last().kind)
    }

    @Test
    fun `pausing while the retry waits leaves it paused and says nothing`() = runTest {
        val h = harness()
        h.failFirst(1)
        h.session.add(listOf(track(1), track(2)), next = false)
        step(500)
        h.session.pause()
        step(LocalSession.RETRY_AFTER_MS * 2)
        assertTrue(h.problems.isEmpty(), "was ${h.problems}")
        assertNull(h.player.loaded, "nothing starts later by itself")
        assertFalse(h.player.playing)
        assertFalse(h.session.snapshot.value.loading)
        assertEquals("Song 1", h.session.snapshot.value.current?.title, "no skipping to the next either")

        h.session.play()
        step()
        assertTrue(h.player.playing, "play starts it again, from a new address")
        assertEquals(listOf(track(1).videoId), h.player.refreshed)
    }

    @Test
    fun `another song chosen while the retry waits drops the retry`() = runTest {
        val h = harness()
        h.player.failWith = { if (it.title == "Song 1") java.io.IOException("blip") else null }
        h.session.add(listOf(track(1), track(2), track(3)), next = false)
        step(500)
        h.session.jump(h.session.snapshot.value.queue[2].id)
        step(LocalSession.RETRY_AFTER_MS * 3)
        assertEquals("Song 3", h.player.loaded?.title)
        assertTrue(h.problems.isEmpty())
        assertEquals(2, h.player.prepareAttempts, "the dropped song was not tried a second time")
    }

    @Test
    fun `a song that will not play, or the lack of a network, is not tried again at once`() = runTest {
        val unplayable = harness()
        unplayable.player.failWith = { LoadFailure(LoadFailure.Reason.UNPLAYABLE, "gone") }
        unplayable.session.add(listOf(track(1)), next = false)
        step(LocalSession.RETRY_AFTER_MS + 500)
        assertEquals(1, unplayable.player.prepareAttempts)

        val offline = harness()
        offline.player.failWith = { LoadFailure(LoadFailure.Reason.OFFLINE, "no network") }
        offline.session.add(listOf(track(1)), next = false)
        step(LocalSession.RETRY_AFTER_MS + 500)
        assertEquals(1, offline.player.prepareAttempts)
    }


    /**
     * Random taps among random failures. With [transientOnly] every failure is a blip, which must never end the queue: the
     * queue ends only when the person goes past its last song. Whatever the failures, it never throws and, when left alone
     * on a good network, settles with nothing still loading.
     */
    private fun checkInvariant(s: LocalSession.Snapshot) {
        if (s.queue.isEmpty()) {
            assertEquals(0, s.index)
            assertTrue(s.queued.isEmpty())
            assertFalse(s.finished)
            return
        }
        assertTrue(s.index in s.queue.indices, "index ${s.index} out of ${s.queue.size}")
        if (s.finished) {
            assertTrue(s.queued.isEmpty(), "finished queue has no waiting queued songs")
            assertTrue(s.queue.none { it.auto }, "finished queue has no waiting auto songs")
            return
        }
        val before = s.queue.take(s.index + 1)
        val after = s.queue.drop(s.index + 1)
        assertTrue(before.none { it.id in s.queued }, "played or current song cannot be in queued")
        assertTrue(before.none { it.auto }, "played or current song cannot be auto")
        val afterIds = after.mapTo(HashSet()) { it.id }
        assertTrue(afterIds.containsAll(s.queued), "every queued id must be after index")
        var tier = 0
        for (item in after) {
            val itemTier = when {
                item.id in s.queued -> {
                    assertFalse(item.auto, "a queued song cannot be auto")
                    0
                }
                !item.auto -> 1
                else -> 2
            }
            assertTrue(itemTier >= tier, "tier order broken after index: saw $itemTier after $tier in ${after.map { "${it.title}(q=${it.id in s.queued},a=${it.auto})" }}")
            tier = itemTier
        }
    }

    @Test
    fun `queued songs play before the rest of the list and play next goes to the front of them`() = runTest {
        val h = harness()
        h.session.playList((1..5).map(::track), start = 1, label = "Lofi Chill")
        step()
        h.session.add(listOf(track(8)), next = false)
        h.session.add(listOf(track(9)), next = false)
        h.session.add(listOf(track(7)), next = true)
        step()
        val s = h.session.snapshot.value
        checkInvariant(s)
        assertEquals("Lofi Chill", s.label)
        assertEquals(listOf("Song 1", "Song 2", "Song 7", "Song 8", "Song 9", "Song 3", "Song 4", "Song 5"), h.titles())
        assertEquals(setOf("Song 7", "Song 8", "Song 9"), s.queue.filter { it.id in s.queued }.map { it.title }.toSet())
        assertEquals("Song 7", h.player.queuedNext?.title)
    }

    @Test
    fun `starting a new list keeps unplayed queued songs right after the chosen song`() = runTest {
        val h = harness()
        h.session.playList((1..4).map(::track), start = 0, label = "Old")
        step()
        h.session.add(listOf(track(8), track(9)), next = false)
        h.session.next()
        step()
        assertEquals("Song 8", h.player.loaded?.title)
        h.session.playList((10..12).map(::track), start = 1, label = "New Album")
        step()
        val s = h.session.snapshot.value
        checkInvariant(s)
        assertEquals("New Album", s.label)
        assertEquals(listOf("Song 10", "Song 11", "Song 9", "Song 12"), h.titles())
        assertEquals(1, s.index)
        assertEquals("Song 11", h.player.loaded?.title)
        assertEquals(listOf("Song 9"), s.queue.filter { it.id in s.queued }.map { it.title })
    }

    @Test
    fun `shuffling only mixes the list and leaves queued songs in order`() = runTest {
        val h = harness()
        h.session.playList((1..8).map(::track), start = 0, label = "Mix")
        step()
        h.session.add(listOf(track(20), track(21)), next = false)
        h.session.setShuffle(true)
        step()
        val mixed = h.session.snapshot.value
        checkInvariant(mixed)
        assertEquals(listOf("Song 1", "Song 20", "Song 21"), h.titles().take(3))
        h.session.shuffle()
        assertEquals(listOf("Song 1", "Song 20", "Song 21"), h.titles().take(3))
        h.session.setShuffle(false)
        assertEquals(listOf("Song 1", "Song 20", "Song 21", "Song 2", "Song 3", "Song 4", "Song 5", "Song 6", "Song 7", "Song 8"), h.titles())
    }

    @Test
    fun `played queued songs stay in history for back but repeat all loops only the list and repeat one repeats a queued song`() = runTest {
        val h = harness()
        h.session.playList((1..3).map(::track), start = 0)
        step()
        h.session.add(listOf(track(9)), next = false)
        h.session.setRepeat("one")
        h.session.next()
        step()
        assertEquals("Song 9", h.player.loaded?.title)
        assertTrue(h.session.snapshot.value.queued.isEmpty(), "once playing, it is no longer waiting in queued")
        h.player.onEnded?.invoke()
        step()
        assertEquals("Song 9", h.player.loaded?.title, "repeat one repeats a queued song too")

        h.session.setRepeat("all")
        h.session.next()
        step()
        assertEquals("Song 2", h.player.loaded?.title)
        h.session.prev()
        step()
        assertEquals("Song 9", h.player.loaded?.title, "back returns to the queued song just heard")
        h.session.next()
        h.session.next()
        step()
        assertEquals("Song 3", h.player.loaded?.title)
        h.session.next()
        step()
        assertEquals("Song 1", h.player.loaded?.title)
        assertEquals(listOf("Song 1", "Song 2", "Song 3"), h.titles(), "repeat all loops only the list, not the one-time queued song")
    }

    @Test
    fun `jumping to a song of the list keeps queued songs waiting right after it`() = runTest {
        val h = harness()
        h.session.playList((1..5).map(::track), start = 0)
        step()
        h.session.add(listOf(track(8), track(9)), next = false)
        val song4 = h.session.snapshot.value.queue.first { it.title == "Song 4" }.id
        h.session.jump(song4)
        step()
        val s = h.session.snapshot.value
        checkInvariant(s)
        assertEquals("Song 4", h.player.loaded?.title)
        assertEquals(3, s.index)
        assertEquals(listOf("Song 1", "Song 2", "Song 3", "Song 4", "Song 8", "Song 9", "Song 5"), h.titles())
        assertEquals(listOf("Song 8", "Song 9"), s.queue.filter { it.id in s.queued }.map { it.title })
    }

    @Test
    fun `jumping to a queued song skips earlier queued songs and keeps the list waiting`() = runTest {
        val h = harness()
        h.session.playList((1..3).map(::track), start = 0)
        step()
        h.session.add(listOf(track(7), track(8), track(9)), next = false)
        val song8 = h.session.snapshot.value.queue.first { it.title == "Song 8" }.id
        h.session.jump(song8)
        step()
        val s = h.session.snapshot.value
        checkInvariant(s)
        assertEquals("Song 8", h.player.loaded?.title)
        assertEquals(2, s.index)
        assertEquals(listOf("Song 1", "Song 7", "Song 8", "Song 9", "Song 2", "Song 3"), h.titles())
        assertEquals(listOf("Song 9"), s.queue.filter { it.id in s.queued }.map { it.title })
    }

    @Test
    fun `moving a song between the two groups changes which group it belongs to`() = runTest {
        val h = harness()
        h.session.playList((1..4).map(::track), start = 0)
        step()
        h.session.add(listOf(track(8), track(9)), next = false)
        val id8 = h.session.snapshot.value.queue.first { it.title == "Song 8" }.id
        h.session.move(id8, toIndex = 3, queued = false)
        checkInvariant(h.session.snapshot.value)
        assertEquals(listOf("Song 1", "Song 9", "Song 2", "Song 8", "Song 3", "Song 4"), h.titles())
        assertEquals(listOf("Song 9"), h.session.snapshot.value.queue.filter { it.id in h.session.snapshot.value.queued }.map { it.title })

        val id3 = h.session.snapshot.value.queue.first { it.title == "Song 3" }.id
        h.session.move(id3, toIndex = 1, queued = true)
        checkInvariant(h.session.snapshot.value)
        assertEquals(listOf("Song 1", "Song 3", "Song 9", "Song 2", "Song 8", "Song 4"), h.titles())
        assertEquals(listOf("Song 3", "Song 9"), h.session.snapshot.value.queue.filter { it.id in h.session.snapshot.value.queued }.map { it.title })
    }

    @Test
    fun `clearing the queued group removes only those songs and leaves the list`() = runTest {
        val h = harness()
        h.session.playList((1..3).map(::track), start = 0, label = "Album")
        step()
        h.session.add(listOf(track(8), track(9)), next = false)
        h.session.clearQueued()
        val s = h.session.snapshot.value
        checkInvariant(s)
        assertTrue(s.queued.isEmpty())
        assertEquals("Album", s.label)
        assertEquals(listOf("Song 1", "Song 2", "Song 3"), h.titles())
        assertEquals("Song 2", h.player.queuedNext?.title)
    }

    @Test
    fun `autoplay songs stay in the third tier behind queued songs and the list`() = runTest {
        val h = harness()
        h.session.playList((1..2).map(::track), start = 1)
        step()
        h.session.add(listOf(track(10), track(11)), next = false, queued = false, auto = true)
        h.session.add(listOf(track(8)), next = false)
        h.session.add(listOf(track(3)), next = false, queued = false)
        val s = h.session.snapshot.value
        checkInvariant(s)
        assertEquals(listOf("Song 1", "Song 2", "Song 8", "Song 3", "Song 10", "Song 11"), h.titles())
        assertEquals(listOf("Song 10", "Song 11"), s.queue.filter { it.auto }.map { it.title })
    }

    @Test
    fun `a song in the list can still be added to the queued group, but not twice to the queued group`() = runTest {
        val h = harness()
        h.session.playList((1..3).map(::track), start = 0)
        step()
        h.session.add(listOf(track(2)), next = false)
        assertEquals(listOf("Song 1", "Song 2", "Song 2", "Song 3"), h.titles())
        h.session.add(listOf(track(2)), next = false)
        assertEquals(listOf("Song 1", "Song 2", "Song 2", "Song 3"), h.titles(), "already in the queued group: not added again")
    }

    @Test
    fun `saved queue remembers the queued group and the list label and reads old files without them`() = runTest {
        val h = harness()
        h.session.playList((1..3).map(::track), start = 0, label = "My List")
        step()
        h.session.add(listOf(track(9)), next = false)
        val lastSaved = h.saved.last()
        assertEquals("My List", lastSaved.label)
        assertEquals(1, lastSaved.queued.size)

        val restored = harness(lastSaved)
        checkInvariant(restored.session.snapshot.value)
        assertEquals("My List", restored.session.snapshot.value.label)
        assertEquals(listOf("Song 1", "Song 9", "Song 2", "Song 3"), restored.titles())
        assertEquals(listOf("Song 9"), restored.session.snapshot.value.queue.filter { it.id in restored.session.snapshot.value.queued }.map { it.title })

        val oldJson = """{"queue":[{"id":"q1","videoId":"aaaaaaaaaaa","title":"One","artist":"x","durMs":1000,"addedBy":""}],"index":0,"repeat":"off","positionMs":0,"finished":false}"""
        val decoded = Protocol.json.decodeFromString<SavedQueue>(oldJson)
        assertTrue(decoded.queued.isEmpty())
        assertNull(decoded.label)
    }

    private fun TestScope.randomTaps(transientOnly: Boolean) {
        for (seed in 1..40) {
            val h = harness()
            val random = Random(seed)
            val kinds = listOf(
                { _: QueueItem -> java.io.IOException("blip") },
                { _: QueueItem -> LoadFailure(LoadFailure.Reason.UNPLAYABLE, "gone") },
                { _: QueueItem -> LoadFailure(LoadFailure.Reason.OFFLINE, "no network") },
            )
            h.player.failWith = { item -> if (random.nextInt(10) < 4) kinds[if (transientOnly) 0 else random.nextInt(kinds.size)](item) else null }
            h.session.add((1..8).map(::track), next = false)
            repeat(150) {
                val snapshot = h.session.snapshot.value
                val queue = snapshot.queue
                val pastTheEnd = snapshot.index + 1 >= queue.size && snapshot.repeat != "all"
                when (random.nextInt(19)) {
                    0, 1 -> if (!pastTheEnd) h.session.next()
                    2 -> h.session.prev()
                    3 -> h.session.pause()
                    4, 5 -> h.session.play()
                    6, 7 -> if (queue.isNotEmpty()) h.session.jump(queue[random.nextInt(queue.size)].id)
                    8 -> h.session.setRepeat(listOf("off", "all", "one")[random.nextInt(3)])
                    9 -> h.session.add(listOf(track(random.nextInt(9, 40))), next = random.nextBoolean())
                    10 -> if (queue.size > 1 && snapshot.index < queue.size - 1) h.session.remove(queue[random.nextInt(queue.size)].id)
                    11 -> h.player.onError?.invoke(RuntimeException("403"))
                    12 -> h.player.prepareDelayMs = random.nextLong(0, 9_000)
                    13 -> h.session.seek(random.nextLong(0, 100_000))
                    14 -> h.session.setShuffle(random.nextBoolean())
                    15 -> if (snapshot.index + 1 < queue.size) h.session.move(queue[random.nextInt(snapshot.index + 1, queue.size)].id, random.nextInt(snapshot.index + 1, queue.size), listOf(null, true, false)[random.nextInt(3)])
                    16 -> h.session.clearQueued()
                    17 -> h.session.playList((1..random.nextInt(2, 7)).map { track(random.nextInt(1, 30)) }, start = random.nextInt(0, 6), label = "L")
                    18 -> h.session.add(listOf(track(random.nextInt(40, 60))), next = false, queued = false, auto = random.nextBoolean())
                }
                checkInvariant(h.session.snapshot.value)
                step(random.nextLong(0, 5_000))
                checkInvariant(h.session.snapshot.value)
                if (transientOnly) assertTrue(h.ended.isEmpty(), "seed $seed: a blip ended the queue, which would start autoplay")
            }
            // Nobody touches it any more, and the network is fine: it settles, with nothing still loading
            h.player.failWith = null
            h.player.prepareDelayMs = 0
            step(120_000)
            assertFalse(h.session.snapshot.value.loading, "seed $seed: it is still loading")
            assertTrue(h.session.snapshot.value.queue.size <= LocalSession.MAX_QUEUE)
        }
    }

    @Test
    fun `random taps among random blips never end the queue or leave it loading for ever`() = runTest { randomTaps(transientOnly = true) }

    @Test
    fun `random taps among every kind of failure never throw or leave it loading for ever`() = runTest { randomTaps(transientOnly = false) }

    @Test
    fun `a stream that keeps breaking is skipped even while repeating that song`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step(1000)
        h.session.setRepeat("one")
        repeat(4) {
            h.player.onError?.invoke(RuntimeException("403"))
            step()
        }
        assertEquals("Song 2", h.player.loaded?.title, "repeating must not load the broken stream for ever")
    }

    @Test
    fun `the queue holds a thousand songs and then says it is full`() = runTest {
        val h = harness()
        h.session.add((1..600).map(::track), next = false)
        step()
        h.session.add((601..1200).map(::track), next = false)
        step()
        assertEquals(1000, h.session.snapshot.value.queue.size)
        h.session.add(listOf(track(1201)), next = false)
        assertTrue(h.problems.any { it.kind == LocalSession.Problem.Kind.QUEUE_FULL })
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

    // ---- Connect: a queue handed to another device. The same cases are in LocalSessionTests.swift and web/local_session_test.dart

    @Test
    fun `a queue handed over keeps what makes it the same queue`() = runTest {
        val a = harness()
        a.session.playList(listOf(track(1), track(2), track(3), track(4)), start = 1, label = "Album")
        a.session.add(listOf(track(5)), next = false)
        a.session.setShuffle(true)
        a.session.setRepeat("all")
        step(5000)
        a.session.pause()
        val handed = a.session.exportQueue()
        assertEquals(0, handed.dropped)
        // It travels as the JSON the queue file is
        val over = Protocol.json.decodeFromString<SavedQueue>(Protocol.json.encodeToString(handed.saved))

        val b = harness()
        b.session.importQueue(over, play = true)
        step()
        val before = a.session.snapshot.value
        val after = b.session.snapshot.value
        assertEquals(before.queue, after.queue)
        assertEquals(before.index, after.index)
        assertEquals("all", after.repeat)
        assertTrue(after.shuffle)
        assertEquals(before.queued, after.queued)
        assertEquals("Album", after.label)
        assertEquals(before.current?.title, b.player.loaded?.title)
        assertTrue(b.player.playing)
        assertTrue(b.player.position in 4000..7000, "went on where it stopped, was ${b.player.position}")
        // Shuffle off puts the songs back in the order they had, as it would have on the first device
        a.session.setShuffle(false)
        b.session.setShuffle(false)
        assertEquals(a.titles(), b.titles())
    }

    @Test
    fun `importing a queue stops what played and without play waits where it was`() = runTest {
        val h = harness()
        h.session.add(listOf(track(1), track(2)), next = false)
        step(3000)
        assertTrue(h.player.playing)
        val song = QueueItem("z", "zzzzzzzzzzz", "Other", "x", null, 200_000, "")
        h.session.importQueue(SavedQueue(listOf(song), positionMs = 42_000), play = false)
        step()
        assertFalse(h.player.playing)
        assertEquals(listOf("Other"), h.titles())
        assertEquals(42_000L, h.session.restoredPositionMs)
    }

    @Test
    fun `the songs only this device has are left out of a hand-over and the index follows the song`() = runTest {
        val one = QueueItem("a", "aaaaaaaaaaa", "One", "x", null, 200_000, "")
        val mine = QueueItem("b", "local:0123456789abcdef", "Mine", "x", null, 200_000, "")
        val three = QueueItem("c", "ccccccccccc", "Three", "x", null, 200_000, "")
        val four = QueueItem("d", "ddddddddddd", "Four", "x", null, 200_000, "")
        // On a song that goes with it
        val on = harness(SavedQueue(listOf(one, mine, three, four), index = 2, positionMs = 9_000, queued = listOf("c", "d"), shuffleOrder = listOf("d", "b", "c", "a")))
        val kept = on.session.exportQueue()
        assertEquals(1, kept.dropped)
        assertEquals(listOf("One", "Three", "Four"), kept.saved.queue.map { it.title })
        assertEquals(1, kept.saved.index)
        assertEquals(9_000L, kept.saved.positionMs)
        assertEquals(listOf("d"), kept.saved.queued, "only what is still to come after the song counts as queued")
        assertEquals(listOf("d", "c", "a"), kept.saved.shuffleOrder)
        // On a song that stays behind: the next that goes, from its start
        val at = harness(SavedQueue(listOf(one, mine, three, four), index = 1, positionMs = 9_000))
        val next = at.session.exportQueue()
        assertEquals(1, next.saved.index)
        assertEquals("Three", next.saved.queue[next.saved.index].title)
        assertEquals(0L, next.saved.positionMs)
        // A queue of nothing but its own music hands over an empty one
        val only = harness(SavedQueue(listOf(mine)))
        assertEquals(SavedQueue(), only.session.exportQueue().saved.copy(label = null))
        assertEquals(1, only.session.exportQueue().dropped)
    }
}
