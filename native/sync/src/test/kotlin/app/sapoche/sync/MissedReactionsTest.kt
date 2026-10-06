package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MissedReactionsTest {

    private var clock = 1_000L
    private val missed = MissedReactions { clock }

    @Test
    fun `taps of one member on one emoji are added up and the order they began is kept`() {
        missed.add("a", "fire", 2)
        missed.add("b", "heart", 1)
        missed.add("a", "fire", 3)
        assertEquals(
            listOf(MissedReactions.Missed("a", "fire", 5), MissedReactions.Missed("b", "heart", 1)),
            missed.take(),
        )
    }

    @Test
    fun `what was taken is not given twice`() {
        missed.add("a", "fire", 1)
        assertEquals(1, missed.take().size)
        assertTrue(missed.take().isEmpty())
    }

    @Test
    fun `reactions older than the time they are kept are left out`() {
        missed.add("a", "old", 1)
        clock += MissedReactions.KEEP_MS + 1
        missed.add("a", "new", 1)
        assertEquals(listOf(MissedReactions.Missed("a", "new", 1)), missed.take())
    }

    @Test
    fun `a pocket full of them keeps the last ones`() {
        repeat(MissedReactions.MAX_ENTRIES + 50) { missed.add("m$it", "fire", 1) }
        val taken = missed.take()
        assertEquals(MissedReactions.MAX_ENTRIES, taken.size)
        assertEquals("m50", taken.first().by)
    }
}
