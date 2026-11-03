package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertEquals

class QueuesTest {

    private fun song(id: String) = TrackRef(id, "Title $id", "Artist", null, 200_000)

    private fun item(id: String) = QueueItem("item-$id", id, "Title $id", "Artist", null, 200_000, addedBy = "")

    private fun ids(list: List<TrackRef>) = list.map { it.videoId }

    private fun auto(id: String) = item(id).copy(auto = true)

    @Test
    fun `a song autoplay lined up may be added by a member, but not the one autoplay is playing`() {
        val queue = listOf(auto("a"), auto("b"), auto("c"))
        assertEquals(listOf("b", "d"), ids(Queues.fresh(listOf(song("a"), song("b"), song("d")), queue, index = 0)))
    }

    @Test
    fun `a song playing now or still to come is not added again`() {
        val queue = listOf(item("a"), item("b"), item("c"))
        assertEquals(listOf("d"), ids(Queues.fresh(listOf(song("b"), song("c"), song("d")), queue, index = 1)))
    }

    @Test
    fun `a song that was played already can be added again`() {
        val queue = listOf(item("a"), item("b"), item("c"))
        assertEquals(listOf("a"), ids(Queues.fresh(listOf(song("a")), queue, index = 1)))
    }

    @Test
    fun `a song repeated within the batch comes once`() {
        assertEquals(listOf("a", "b"), ids(Queues.fresh(listOf(song("a"), song("b"), song("a")), emptyList(), index = 0)))
    }

    @Test
    fun `an empty queue takes everything`() {
        assertEquals(listOf("a", "b"), ids(Queues.fresh(listOf(song("a"), song("b")), emptyList(), index = 0)))
    }

    @Test
    fun `an index past the end leaves nothing waiting`() {
        assertEquals(listOf("a"), ids(Queues.fresh(listOf(song("a")), listOf(item("a")), index = 5)))
    }

    private fun by(id: String, member: String, auto: Boolean = false) = item(id).copy(addedBy = member, auto = auto)

    @Test
    fun `a room where one member added everything is asked about the last song alone`() {
        val queue = listOf(by("a", "m1"), by("b", "m1"), by("c", "m1"))
        assertEquals(listOf("c"), Queues.seeds(queue, "c"))
    }

    @Test
    fun `each member who has a song in the queue gives one seed, the latest first, up to three`() {
        val queue = listOf(by("a", "m1"), by("b", "m2"), by("c", "m3"), by("d", "m4"), by("e", "m1"))
        // The last song is m1's; then m4's d, m3's c; m2's b is past the limit
        assertEquals(listOf("e", "d", "c"), Queues.seeds(queue, "e"))
        assertEquals(listOf("e", "d"), Queues.seeds(queue, "e", max = 2))
    }

    @Test
    fun `songs autoplay added are nobody's choice, and a member counts once`() {
        val queue = listOf(by("a", "m1"), by("b", "m2"), by("x", "m3", auto = true), by("c", "m2"), by("y", "m1", auto = true))
        // The last song is autoplay's, so m1 and m2 are both still to be heard: m2's latest is c, then m1's a
        assertEquals(listOf("y", "c", "a"), Queues.seeds(queue, "y"))
    }

    @Test
    fun `the song asked about is always there, even when it left the queue`() {
        val queue = listOf(by("a", "m1"), by("b", "m2"))
        assertEquals(listOf("gone", "b", "a"), Queues.seeds(queue, "gone"))
    }

    @Test
    fun `an empty queue gives the song asked about`() {
        assertEquals(listOf("z"), Queues.seeds(emptyList(), "z"))
    }

    @Test
    fun `a song of each member's offer joins the seeds, going round with the epoch`() {
        val offers = listOf(listOf("a1", "a2", "a3"), listOf("b1", "b2"), emptyList(), listOf("c1"))
        // The first song of each, from the first member; the one who offered nothing is not there
        assertEquals(listOf("x", "a1", "b1", "c1"), Queues.blend(listOf("x"), offers, epoch = 0))
        // Next time the room runs out it is the second song of those who gave more than one, and the members start elsewhere
        assertEquals(listOf("x", "b2", "c1", "a2"), Queues.blend(listOf("x"), offers, epoch = 1))
    }

    @Test
    fun `no more than five radios are asked for, and a song already a seed is not taken twice`() {
        val offers = listOf(listOf("a"), listOf("b"), listOf("c"), listOf("d"))
        assertEquals(listOf("x", "y", "z", "a", "b"), Queues.blend(listOf("x", "y", "z"), offers, epoch = 0))
        assertEquals(listOf("x", "y", "z", "b", "c"), Queues.blend(listOf("x", "y", "z"), offers, epoch = 1))
        assertEquals(listOf("a", "b"), Queues.blend(listOf("a"), listOf(listOf("a", "b")), epoch = 0))
        assertEquals(listOf("x"), Queues.blend(listOf("x"), emptyList(), epoch = 7))
    }
}
