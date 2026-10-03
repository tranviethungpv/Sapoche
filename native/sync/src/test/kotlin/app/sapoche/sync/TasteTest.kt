package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TasteTest {
    private val day = 24L * 60 * 60 * 1000
    private val now = 1_000 * day

    private fun song(id: String, artist: String = "Artist $id") = TrackRef(id, "Title $id", artist, null, 200_000)

    private fun heard(id: String, daysAgo: Int = 1, artist: String = "Artist $id") = Stamped(song(id, artist), now - daysAgo * day)

    private fun taste(
        heard: List<Stamped> = emptyList(),
        liked: List<Stamped> = emptyList(),
        skipped: List<Stamped> = emptyList(),
        hourOf: (Long) -> Int = { 12 },
    ) = Taste(heard, liked, skipped, now, hourOf)

    @Test
    fun `an artist is known once listened to`() {
        val taste = taste(heard = listOf(heard("a", artist = "Jack, K-ICM")))
        assertTrue(taste.knows("Jack"))
        assertTrue(taste.knows("jack - Topic"))
        assertFalse(taste.knows("Someone else"))
    }

    @Test
    fun `old listens count for less than new ones`() {
        val taste = taste(heard = listOf(heard("old", daysAgo = 90), heard("new", daysAgo = 1)))
        // Three half-lives later a listen is worth an eighth: the artist is not known any more
        assertFalse(taste.knows("Artist old"))
        assertTrue(taste.knows("Artist new"))
    }

    @Test
    fun `songs left again and again make an artist disliked`() {
        val skips = listOf(heard("a", 1, "Same"), heard("b", 2, "Same"))
        val taste = taste(skipped = skips)
        assertTrue(taste.dislikes("Same"))
        // A heard song of the artist makes up for a skip
        val mixed = taste(heard = listOf(heard("c", 1, "Same")), skipped = skips)
        assertFalse(mixed.dislikes("Same"))
    }

    @Test
    fun `a like weighs more than a listen`() {
        val taste = taste(heard = listOf(heard("a"), heard("b"), heard("b", 2)), liked = listOf(heard("a")))
        assertEquals(listOf("a", "b"), taste.seeds(2), "a: 1 listen and a like beat b: 2 listens")
    }

    @Test
    fun `seeds are the best loved songs, one for each artist`() {
        val listens = listOf(
            heard("a1", 1, "A"), heard("a1", 2, "A"), heard("a1", 3, "A"),
            heard("a2", 1, "A"), heard("a2", 2, "A"),
            heard("b1", 1, "B"),
            heard("c1", 1, "C"),
        )
        assertEquals(listOf("a1", "b1", "c1"), taste(heard = listens).seeds(3))
    }

    @Test
    fun `a second song of an artist fills a seed that would be empty`() {
        val listens = listOf(heard("a1", 1, "A"), heard("a1", 2, "A"), heard("a2", 1, "A"), heard("b1", 1, "B"))
        assertEquals(listOf("a1", "b1", "a2"), taste(heard = listens).seeds(3))
    }

    @Test
    fun `songs that were only skipped are not seeds, nor are blocked ones`() {
        val taste = taste(heard = listOf(heard("a"), heard("b"), heard("c")), skipped = listOf(heard("c"), heard("c", 2)))
        assertEquals(listOf("a", "b"), taste.seeds(5, Blocklist()))
        assertEquals(listOf("b"), taste.seeds(5, Blocklist(songs = setOf("a"))))
        assertEquals(listOf("a"), taste.seeds(5, Blocklist(artists = setOf("artist b"))))
    }

    @Test
    fun `nothing is known about someone who has not listened`() {
        val taste = taste()
        assertEquals(emptyList(), taste.seeds(5))
        assertFalse(taste.knows("Anyone"))
        assertFalse(taste.dislikes("Anyone"))
    }

    @Test
    fun `the time of day is cut in four`() {
        assertEquals(
            listOf("night", "morning", "morning", "afternoon", "afternoon", "evening", "evening", "night"),
            listOf(4, 5, 10, 11, 16, 17, 21, 22).map(Taste::bucketOf),
        )
    }

    @Test
    fun `what is played at this hour seeds the mix for it`() {
        // Each listen has a moment of its own, so the test can say which hour it was at
        fun at(id: String, daysAgo: Int, ms: Long) = Stamped(song(id), now - daysAgo * day - ms)
        val morning = (1..5).map { at("m1", it, 1_000) } + (1..2).map { at("m2", it, 2_000) }
        val evening = (1..3).map { at("e1", it, 3_000) }
        val hours = mapOf(1_000L to 8, 2_000L to 8, 3_000L to 20)
        val taste = taste(heard = morning + evening, hourOf = { hours.getValue((now - it) % day) })
        assertEquals(listOf("m1", "m2"), taste.contextSeeds("morning").map { it.videoId })
        assertEquals(emptyList(), taste.contextSeeds("evening").map { it.videoId }, "three listens do not make a habit")
        assertEquals(emptyList(), taste.contextSeeds("night"))
    }

    @Test
    fun `two songs of one artist are one seed for a time of day`() {
        val listens = (1..4).map { heard("s1", it, "Same") } + (1..3).map { heard("s2", it, "Same") } + listOf(heard("o", 1, "Other"))
        val taste = taste(heard = listens)
        assertEquals(listOf("s1", "o"), taste.contextSeeds("afternoon").map { it.videoId })
    }

    @Test
    fun `an artist is a name in plain letters`() {
        assertEquals("sơn tùng m tp", Taste.artistKey("Sơn Tùng M-TP"))
        assertEquals("jack", Taste.artistKey("Jack & K-ICM"))
        assertEquals("noo phước thịnh", Taste.artistKey("Noo Phước Thịnh - Topic"))
        assertEquals("Jack", Taste.artistLabel("Jack, K-ICM"))
    }
}
