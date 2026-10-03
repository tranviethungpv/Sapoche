package app.sapoche.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AudioPickerTest {

    private fun source(itag: Int, kbps: Int) = AudioSource("https://x/$itag", "codec", kbps, 1000, itag)

    private val opus = source(251, 160)
    private val aac = source(140, 128)
    private val low = source(249, 50)

    @Test
    fun `without a pin the best bitrate wins`() {
        val pick = AudioPicker.pick(listOf(low, aac, opus), null)!!
        assertEquals(251, pick.source.itag)
        assertTrue(pick.honoursPin, "nothing was pinned, so nothing is broken")
    }

    @Test
    fun `a pinned stream is used even when another is better`() {
        val pick = AudioPicker.pick(listOf(opus, aac), pinned = 140)!!
        assertEquals(140, pick.source.itag)
        assertTrue(pick.honoursPin)
    }

    @Test
    fun `a pin the video no longer offers falls back to the best and says so`() {
        val pick = AudioPicker.pick(listOf(opus, aac), pinned = 18)!!
        assertEquals(251, pick.source.itag)
        assertFalse(pick.honoursPin)
    }

    @Test
    fun `no streams, no pick`() {
        assertNull(AudioPicker.pick(emptyList(), null))
        assertNull(AudioPicker.pick(emptyList(), 251))
    }
}
