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

    private val middle = source(250, 70)
    private val all = listOf(opus, aac, middle, low)

    private fun chosen(quality: AudioQuality, sources: List<AudioSource> = all) =
        AudioPicker.pick(sources, null, quality)!!.source.itag

    @Test
    fun `each step takes the best stream within its limit`() {
        assertEquals(249, chosen(AudioQuality.LOW))
        assertEquals(250, chosen(AudioQuality.NORMAL))
        assertEquals(140, chosen(AudioQuality.HIGH))
        assertEquals(251, chosen(AudioQuality.MAX))
    }

    @Test
    fun `a video with nothing that low gets its smallest stream`() {
        assertEquals(140, chosen(AudioQuality.LOW, listOf(opus, aac)))
        assertEquals(140, chosen(AudioQuality.NORMAL, listOf(opus, aac)))
        assertEquals(140, chosen(AudioQuality.HIGH, listOf(opus, aac)))
    }

    @Test
    fun `the order of the streams does not matter`() {
        for (quality in AudioQuality.entries) {
            assertEquals(chosen(quality), chosen(quality, all.reversed()), quality.name)
        }
    }

    @Test
    fun `a pin beats the step`() {
        assertEquals(251, AudioPicker.pick(all, pinned = 251, quality = AudioQuality.LOW)!!.source.itag)
    }

    @Test
    fun `a pin that is gone falls back to the step and says so`() {
        val pick = AudioPicker.pick(all, pinned = 18, quality = AudioQuality.LOW)!!
        assertEquals(249, pick.source.itag)
        assertFalse(pick.honoursPin)
    }

    @Test
    fun `a saved level maps back to its step and an unknown one to the best`() {
        for (quality in AudioQuality.entries) assertEquals(quality, AudioQuality.of(quality.level))
        assertEquals(AudioQuality.MAX, AudioQuality.of(9))
        assertEquals(AudioQuality.MAX, AudioQuality.of(-1))
    }
}
