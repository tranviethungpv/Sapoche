package app.sapoche.core

/**
 * Chooses which audio stream of a video to play or keep. Bytes of a song kept on disk belong to one stream
 * (one itag), and bytes of two streams must never be mixed in one file, so once some are kept that stream
 * has to be used again.
 */
object AudioPicker {

    /** The stream to use and whether it is the [pinned] one, or null for [pinned] when nothing is kept yet. */
    data class Pick(val source: AudioSource, val honoursPin: Boolean)

    /**
     * The stream with the itag [pinned] if the video still offers it, else the one with the highest bitrate.
     * [honoursPin] is false when a pin existed but could not be followed: what was kept is of no use then.
     * Null when there are no streams.
     */
    fun pick(sources: List<AudioSource>, pinned: Int?): Pick? {
        if (sources.isEmpty()) return null
        if (pinned != null) sources.firstOrNull { it.itag == pinned }?.let { return Pick(it, true) }
        return Pick(sources.maxByOrNull { it.bitrateKbps }!!, pinned == null)
    }
}
