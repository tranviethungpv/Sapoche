package app.sapoche.core

/** Chooses which video-only stream to play beside the audio. */
object VideoPicker {

    /**
     * The tallest stream that fits within [maxHeight], preferring H.264 in MP4 because every phone
     * decodes it in hardware. When nothing fits (the video has only larger streams) the smallest
     * available one is used rather than none at all.
     */
    fun pick(sources: List<VideoSource>, maxHeight: Int): VideoSource? {
        if (sources.isEmpty()) return null
        val fitting = sources.filter { it.height <= maxHeight }
        if (fitting.isEmpty()) return sources.minByOrNull { it.height }
        val tallest = fitting.maxOf { it.height }
        val atTallest = fitting.filter { it.height == tallest }
        return atTallest.firstOrNull { it.isH264 } ?: atTallest.maxByOrNull { it.bitrateKbps }
    }

    private val VideoSource.isH264: Boolean
        get() = format.equals("MPEG_4", ignoreCase = true) && codec.startsWith("avc1")
}
