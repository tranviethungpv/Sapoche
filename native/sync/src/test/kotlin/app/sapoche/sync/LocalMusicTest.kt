package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class LocalMusicTest {

    private fun file(key: String, title: String = "Song", artist: String = "Artist", durMs: Long = 200_000) =
        LocalFile(key, "content://media/$key", title, artist, "Album", durMs, "audio/mpeg", 4_000_000, 1)

    private fun known(id: String, key: String, title: String = "Song", artist: String = "Artist", durMs: Long = 200_000, referenced: Boolean = true) =
        KnownLocal(id, key, title, artist, durMs, referenced)

    @Test
    fun `an id never looks like the id of a YouTube video`() {
        val id = LocalMusic.id("Music/a.mp3")
        assertTrue(LocalMusic.isLocal(id))
        assertEquals(6 + 16, id.length)
        assertFalse(Regex("^[A-Za-z0-9_-]{11}$").matches(id))
        assertFalse(LocalMusic.isLocal("dQw4w9WgXcQ"))
    }

    @Test
    fun `an id is the same for the same key and differs between keys and attempts`() {
        assertEquals(LocalMusic.id("Music/a.mp3"), LocalMusic.id("Music/a.mp3"))
        assertNotEquals(LocalMusic.id("Music/a.mp3"), LocalMusic.id("Music/b.mp3"))
        assertNotEquals(LocalMusic.id("Music/a.mp3"), LocalMusic.id("Music/a.mp3", attempt = 1))
        // Fixed on purpose, so that the Swift side can be held to the same values
        assertEquals("local:af63dc4c8601ec8c", LocalMusic.id("a"))
        assertEquals("local:cbf29ce484222325", LocalMusic.id(""))
    }

    @Test
    fun `a file seen before keeps its id`() {
        val plan = LocalMusic.plan(listOf(file("k1", title = "Renamed")), listOf(known("local:1", "k1")))
        assertEquals(listOf("local:1"), plan.files.map { it.first })
        assertTrue(plan.missing.isEmpty() && plan.forget.isEmpty())
    }

    @Test
    fun `a new file gets the id of its key`() {
        val plan = LocalMusic.plan(listOf(file("k1")), emptyList())
        assertEquals(listOf(LocalMusic.id("k1")), plan.files.map { it.first })
    }

    @Test
    fun `a file that is gone but is still pointed to is kept as missing, the others are forgotten`() {
        val plan = LocalMusic.plan(
            emptyList(),
            listOf(known("local:1", "k1", referenced = true), known("local:2", "k2", referenced = false)),
        )
        assertEquals(listOf("local:1"), plan.missing)
        assertEquals(listOf("local:2"), plan.forget)
    }

    @Test
    fun `a file that moved takes its song over, so likes and playlists stay`() {
        val plan = LocalMusic.plan(
            listOf(file("new/place.mp3", durMs = 201_000)),
            listOf(known("local:1", "old/place.mp3")),
        )
        assertEquals(listOf("local:1"), plan.files.map { it.first })
        assertEquals("new/place.mp3", plan.files.single().second.key)
        assertTrue(plan.missing.isEmpty() && plan.forget.isEmpty())
    }

    @Test
    fun `a moved file is told by title and artist whatever the case and spacing`() {
        val plan = LocalMusic.plan(
            listOf(file("n", title = "  my   SONG ", artist = "the artist")),
            listOf(known("local:1", "o", title = "My Song", artist = "The Artist")),
        )
        assertEquals("local:1", plan.files.single().first)
    }

    @Test
    fun `a file of another length is another song`() {
        val plan = LocalMusic.plan(listOf(file("n", durMs = 230_000)), listOf(known("local:1", "o", durMs = 200_000)))
        assertEquals(LocalMusic.id("n"), plan.files.single().first)
        assertEquals(listOf("local:1"), plan.missing)
    }

    @Test
    fun `nothing is joined when two missing files look like the new one`() {
        val plan = LocalMusic.plan(
            listOf(file("n")),
            listOf(known("local:1", "o1"), known("local:2", "o2")),
        )
        assertEquals(LocalMusic.id("n"), plan.files.single().first)
        assertEquals(listOf("local:1", "local:2"), plan.missing)
    }

    @Test
    fun `nothing is joined when two new files look like the missing one`() {
        val plan = LocalMusic.plan(listOf(file("n1"), file("n2")), listOf(known("local:1", "o")))
        assertEquals(listOf(LocalMusic.id("n1"), LocalMusic.id("n2")), plan.files.map { it.first })
        assertEquals(listOf("local:1"), plan.missing)
    }

    @Test
    fun `a new file whose id is taken by another song gets another id`() {
        val taken = LocalMusic.id("k")
        val plan = LocalMusic.plan(listOf(file("k"), file("other", title = "Else")), listOf(known(taken, "moved-away", title = "Else 2")))
        val id = plan.files.first { it.second.key == "k" }.first
        assertNotEquals(taken, id)
        assertTrue(LocalMusic.isLocal(id))
    }

    @Test
    fun `the cover address names the song`() {
        assertEquals("sapoche-local:local:1", LocalMusic.cover("local:1"))
    }
}
