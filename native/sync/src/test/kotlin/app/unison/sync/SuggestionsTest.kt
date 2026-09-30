package app.unison.sync

import kotlin.test.Test
import kotlin.test.assertEquals

class SuggestionsTest {

    private fun song(id: String, sec: Long = 200) = TrackRef(id, "Title $id", "Artist", null, sec * 1000)

    private fun ids(list: List<TrackRef>) = list.map { it.videoId }

    @Test
    fun `seeds take turns`() {
        val mixed = Suggestions.mix(
            listOf(listOf(song("a1"), song("a2"), song("a3")), listOf(song("b1"), song("b2")), listOf(song("c1"))),
            exclude = emptySet(),
            limit = 10,
        )
        assertEquals(listOf("a1", "b1", "c1", "a2", "b2", "a3"), ids(mixed))
    }

    @Test
    fun `hour long mixes and clips are not songs`() {
        val mixed = Suggestions.mix(
            listOf(listOf(song("mix", 3600), song("clip", 20), song("ok", 200), song("edge", 600), song("short", 60))),
            emptySet(),
            10,
        )
        assertEquals(listOf("ok", "edge", "short"), ids(mixed))
    }

    @Test
    fun `songs already known are left out`() {
        val mixed = Suggestions.mix(listOf(listOf(song("a"), song("b"), song("c"))), exclude = setOf("a", "c"), limit = 10)
        assertEquals(listOf("b"), ids(mixed))
    }

    @Test
    fun `a song two seeds agree on comes once`() {
        val mixed = Suggestions.mix(listOf(listOf(song("x"), song("a")), listOf(song("x"), song("b"))), emptySet(), 10)
        assertEquals(listOf("x", "b", "a"), ids(mixed), "the second seed skips the repeat and gives its next song")
    }

    @Test
    fun `it stops at the limit`() {
        val mixed = Suggestions.mix(listOf(listOf(song("a"), song("b")), listOf(song("c"), song("d"))), emptySet(), 3)
        assertEquals(listOf("a", "c", "b"), ids(mixed))
    }

    @Test
    fun `a seed that has nothing does not hold up the others`() {
        val mixed = Suggestions.mix(listOf(emptyList(), listOf(song("a"), song("b"))), emptySet(), 10)
        assertEquals(listOf("a", "b"), ids(mixed))
    }

    @Test
    fun `nothing in, nothing out`() {
        assertEquals(emptyList(), Suggestions.mix(emptyList(), emptySet(), 5))
        assertEquals(emptyList(), Suggestions.mix(listOf(listOf(song("a"))), emptySet(), 0))
    }
}
