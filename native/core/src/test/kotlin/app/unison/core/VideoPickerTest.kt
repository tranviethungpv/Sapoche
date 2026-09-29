package app.unison.core

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
}
