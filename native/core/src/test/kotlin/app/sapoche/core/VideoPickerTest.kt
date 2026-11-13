package app.sapoche.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class VideoPickerTest {
    private fun source(height: Int, format: String = "MPEG_4", codec: String = "avc1.4d401f", kbps: Int = 1000) =
        VideoSource("http://v/$height/$format", height, format, codec, kbps, 1L, height)

    @Test
    fun `the tallest stream within the limit wins`() {
        val sources = listOf(source(1080), source(720), source(480), source(360))
        assertEquals(720, VideoPicker.pick(sources, 720)?.height)
        assertEquals(360, VideoPicker.pick(sources, 360)?.height)
        assertEquals(1080, VideoPicker.pick(sources, 2160)?.height)
    }

    @Test
    fun `at the same height H264 in MP4 is preferred over VP9`() {
        val vp9 = source(720, format = "WEBM", codec = "vp09.00.40.08", kbps = 3000)
        val h264 = source(720, kbps = 1500)
        assertEquals(h264, VideoPicker.pick(listOf(vp9, h264), 720))
    }

    @Test
    fun `without H264 the higher bitrate one is taken`() {
        val low = source(720, format = "WEBM", codec = "vp09", kbps = 1000)
        val high = source(720, format = "WEBM", codec = "vp09", kbps = 2000)
        assertEquals(high, VideoPicker.pick(listOf(low, high), 720))
    }

    @Test
    fun `when everything is taller than the limit the smallest is used`() {
        assertEquals(1080, VideoPicker.pick(listOf(source(2160), source(1080)), 720)?.height)
    }

    @Test
    fun `no streams means no video`() {
        assertNull(VideoPicker.pick(emptyList(), 720))
    }

    @Test
    fun `a link that cannot carry the stream gets the tallest one it can`() {
        val sources = listOf(source(1080, kbps = 4200), source(720, kbps = 2200), source(480, kbps = 900), source(360, kbps = 500))
        assertEquals(1080, VideoPicker.pick(sources, 1080, budgetKbps = 5000)?.height)
        assertEquals(720, VideoPicker.pick(sources, 1080, budgetKbps = 2500)?.height)
        assertEquals(480, VideoPicker.pick(sources, 1080, budgetKbps = 1000)?.height)
        assertEquals(480, VideoPicker.pick(sources, 480, budgetKbps = 5000)?.height, "the setting is still the most")
    }

    @Test
    fun `when nothing fits the budget the smallest picture is used`() {
        val sources = listOf(source(1080, kbps = 4200), source(720, kbps = 2200), source(360, kbps = 500))
        assertEquals(360, VideoPicker.pick(sources, 1080, budgetKbps = 100)?.height)
        assertEquals(360, VideoPicker.pick(sources, 1080, budgetKbps = 1)?.height)
    }

    @Test
    fun `a taller picture of another codec does not beat an H264 one that fits`() {
        val vp9 = source(1080, format = "WEBM", codec = "vp09.00.40.08", kbps = 1800)
        val h264Big = source(1080, kbps = 4200)
        val h264 = source(720, kbps = 1500)
        assertEquals(h264, VideoPicker.pick(listOf(vp9, h264Big, h264), 1080, budgetKbps = 2700))
        assertEquals(h264Big, VideoPicker.pick(listOf(vp9, h264Big, h264), 1080, budgetKbps = 0))
        assertEquals(vp9, VideoPicker.pick(listOf(vp9, source(1080, kbps = 4200)), 1080, budgetKbps = 2700), "when no H264 one fits")
    }

    @Test
    fun `no budget is no limit`() {
        val sources = listOf(source(1080, kbps = 4200), source(720, kbps = 2200))
        assertEquals(1080, VideoPicker.pick(sources, 1080, budgetKbps = 0)?.height)
    }

    @Test
    fun `the budget is two thirds of the bandwidth less the sound`() {
        assertEquals(0L, VideoPicker.budgetKbps(0, weak = false))
        assertEquals(1L, VideoPicker.budgetKbps(0, weak = true))
        assertEquals(2706L, VideoPicker.budgetKbps(4300, weak = false))
        assertEquals(1L, VideoPicker.budgetKbps(150, weak = false), "never below one: 0 would mean no limit")
    }
}
