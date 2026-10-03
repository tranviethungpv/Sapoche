package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertEquals

class QueuesTest {

    private fun song(id: String) = TrackRef(id, "Title $id", "Artist", null, 200_000)

    private fun item(id: String) = QueueItem("item-$id", id, "Title $id", "Artist", null, 200_000, addedBy = "")

    private fun ids(list: List<TrackRef>) = list.map { it.videoId }

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
}
