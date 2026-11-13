package app.sapoche.core

/** Chooses which video-only stream to play beside the audio. */
object VideoPicker {

    /** What the sound that plays beside the picture takes, off the share of the link the picture may have. */
    private const val SOUND_KBPS = 160L

    /**
     * What the picture may take, in kbps, of a link that [bandwidthKbps] was measured to carry: two thirds of it, as the
     * audio's steps keep room to spare, less what the sound takes. 0 means no limit (nothing was measured); on a [weak]
     * network with nothing measured it is 1, which picks the least demanding picture there is.
     */
    fun budgetKbps(bandwidthKbps: Long, weak: Boolean): Long {
        if (bandwidthKbps <= 0) return if (weak) 1 else 0
        return maxOf(1L, bandwidthKbps * 2 / 3 - SOUND_KBPS)
    }

    /**
     * The tallest stream that fits within [maxHeight] and, when [budgetKbps] is above 0, takes no more than it. H.264
     * in MP4 comes first, because every phone decodes it in hardware and another codec may be decoded by the processor,
     * which is what makes a phone hot: a taller picture of another codec is taken only when no H.264 one fits. At the
     * height chosen the one with most bitrate that still fits. When nothing fits (the video has only larger streams,
     * or only dearer ones) the smallest available one is used rather than none at all.
     */
    fun pick(sources: List<VideoSource>, maxHeight: Int, budgetKbps: Long = 0): VideoSource? {
        if (sources.isEmpty()) return null
        val fitting = sources.filter { it.height <= maxHeight && (budgetKbps <= 0 || it.bitrateKbps <= budgetKbps) }
        if (fitting.isEmpty()) return sources.minWithOrNull(compareBy({ it.height }, { it.bitrateKbps }))
        val pool = fitting.filter { it.isH264 }.ifEmpty { fitting }
        val tallest = pool.maxOf { it.height }
        return pool.filter { it.height == tallest }.maxByOrNull { it.bitrateKbps }
    }

    private val VideoSource.isH264: Boolean
        get() = format.equals("MPEG_4", ignoreCase = true) && codec.startsWith("avc1")
}
