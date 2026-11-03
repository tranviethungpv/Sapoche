package app.sapoche.sync

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

    private fun by(id: String, artist: String) = TrackRef(id, "Title $id", artist, null, 200_000)

    private fun tasteOf(vararg known: String): Taste {
        val now = 1_000L * 24 * 60 * 60 * 1000
        return Taste(known.mapIndexed { i, a -> Stamped(by("k$i", a), now - 1000) }, emptyList(), emptyList(), now)
    }

    @Test
    fun `what the mix is told to refuse stays out`() {
        val mixed = Suggestions.mix(listOf(listOf(song("a"), song("b"), song("c"))), emptySet(), 10) { it.videoId != "b" }
        assertEquals(listOf("a", "c"), ids(mixed))
    }

    @Test
    fun `mostly artists the person knows, with new ones in between`() {
        val known = (1..9).map { by("k$it", "Known $it") }
        val fresh = (1..9).map { by("f$it", "Fresh $it") }
        val taste = tasteOf(*(1..9).map { "Known $it" }.toTypedArray())
        val mixed = Suggestions.compose(listOf(known + fresh), taste, Blocklist(), emptySet(), 10)
        // Three of ten come from artists the person does not know, at the third, sixth and ninth place
        assertEquals(listOf("k1", "k2", "f1", "k3", "k4", "f2", "k5", "k6", "f3", "k7"), ids(mixed))
    }

    @Test
    fun `when one kind runs out the other fills the list`() {
        val taste = tasteOf("Known")
        val onlyFresh = Suggestions.compose(listOf(listOf(by("f1", "A"), by("f2", "B"), by("f3", "C"))), taste, Blocklist(), emptySet(), 10)
        assertEquals(listOf("f1", "f2", "f3"), ids(onlyFresh))
        val onlyKnown = Suggestions.compose(
            listOf(listOf(by("k1", "Known"), by("k2", "Known"), by("k3", "Known"))), taste, Blocklist(), emptySet(), 10,
        )
        assertEquals(listOf("k1", "k2"), ids(onlyKnown), "and no artist comes more than twice")
    }

    @Test
    fun `blocked and disliked artists are never offered`() {
        val now = 1_000L * 24 * 60 * 60 * 1000
        val skipped = listOf(Stamped(by("s1", "Disliked"), now - 1000), Stamped(by("s2", "Disliked"), now - 2000))
        val taste = Taste(emptyList(), emptyList(), skipped, now)
        val lists = listOf(listOf(by("a", "Disliked"), by("b", "Blocked"), by("c", "Fine"), by("d", "Fine 2")))
        val mixed = Suggestions.compose(lists, taste, Blocklist(artists = setOf("blocked")), setOf("d"), 10)
        assertEquals(listOf("c"), ids(mixed))
    }

    @Test
    fun `discover offers one song of each artist that is new`() {
        val taste = tasteOf("Known")
        val lists = listOf(
            listOf(by("k1", "Known"), by("n1", "New"), by("n2", "New"), by("m1", "More")),
            listOf(by("o1", "Other"), by("n3", "New")),
        )
        assertEquals(listOf("n1", "o1", "m1"), ids(Suggestions.discover(lists, taste, Blocklist(), emptySet(), 10)))
        assertEquals(listOf("n1"), ids(Suggestions.discover(lists, taste, Blocklist(), emptySet(), 1)))
    }

    @Test
    fun `ranking keeps the order of the radio for a stranger`() {
        val list = listOf(by("a", "X"), by("b", "Y"), by("c", "Z"), by("d", "W"))
        assertEquals(listOf("a", "b", "c", "d"), ids(Suggestions.rank(list, Taste(emptyList(), emptyList(), emptyList(), 0))))
    }

    @Test
    fun `ranking lifts songs by artists the person loves, a few places at most`() {
        val taste = tasteOf("Loved")
        // The loved artist's song stands fifth: what it adds is worth four places, and no more
        val list = listOf(by("a", "A"), by("b", "B"), by("c", "C"), by("d", "D"), by("e", "Loved"))
        assertEquals(listOf("e", "a", "b", "c", "d"), ids(Suggestions.rank(list, taste)))
        val far = listOf(by("a", "A"), by("b", "B"), by("c", "C"), by("d", "D"), by("e", "E"), by("f", "F"), by("g", "G"), by("h", "H"), by("i", "Loved"))
        assertEquals("a", ids(Suggestions.rank(far, taste)).first(), "at the ninth place it does not reach the top")
    }

    @Test
    fun `a song left more than it was heard is dropped`() {
        val now = 1_000L * 24 * 60 * 60 * 1000
        val skipped = listOf(Stamped(by("bad", "Y"), now - 1000))
        val taste = Taste(emptyList(), emptyList(), skipped, now)
        assertEquals(listOf("ok"), ids(Suggestions.rank(listOf(by("bad", "Y"), by("ok", "Z")), taste)))
    }

    @Test
    fun `no artist comes more than twice`() {
        val taste = tasteOf("Known")
        val list = (1..8).map { by("k$it", "Known") } + listOf(by("n1", "New 1"), by("n2", "New 2"))
        assertEquals(listOf("k1", "k2", "n1", "n2"), ids(Suggestions.rank(list, taste)))
    }

    @Test
    fun `every fifth place is for an artist not known yet when the list has one`() {
        val taste = tasteOf("A", "B", "C", "D", "E")
        val list = listOf(by("a", "A"), by("b", "B"), by("c", "C"), by("d", "D"), by("e", "E"), by("s", "Stranger"))
        // By score e would be fifth; the place is for the stranger
        assertEquals(listOf("a", "b", "c", "d", "s", "e"), ids(Suggestions.rank(list, taste)))
        // With no stranger in the list the place goes to whoever is next
        assertEquals(listOf("a", "b", "c", "d", "e"), ids(Suggestions.rank(list.dropLast(1), taste)))
    }

    @Test
    fun `ranking gives the same order every time`() {
        val taste = tasteOf("Known")
        val list = listOf(by("a", "Known"), by("b", "B"), by("c", "Known"), by("d", "D"), by("e", "E"), by("f", "F"))
        assertEquals(ids(Suggestions.rank(list, taste)), ids(Suggestions.rank(list, taste)))
    }

    @Test
    fun `an artist the person wants fewer suggestions of is no stranger to be tried`() {
        val now = 1_000L * 24 * 60 * 60 * 1000
        val taste = Taste(listOf(Stamped(by("k0", "Known"), now - 1000)), emptyList(), emptyList(), now, quietArtists = setOf("quiet"))
        val lists = listOf(listOf(by("q1", "Quiet"), by("n1", "New"), by("k1", "Known")))
        assertEquals(listOf("n1"), ids(Suggestions.discover(lists, taste, Blocklist(), emptySet(), 10)))
        assertEquals(listOf("k1", "n1"), ids(Suggestions.compose(lists, taste, Blocklist(), emptySet(), 10)))
        // And autoplay does not keep a place for them either
        val ranked = Suggestions.rank(listOf(by("a", "Known"), by("b", "Known 2"), by("c", "Known 3"), by("d", "Known 4"), by("q", "Quiet"), by("s", "Stranger")), taste)
        assertEquals("s", ranked[4].videoId)
    }
}
