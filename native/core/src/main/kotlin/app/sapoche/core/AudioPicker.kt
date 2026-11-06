package app.sapoche.core

/**
 * How much sound a song is fetched in, from the least data to the most YouTube offers. [level] is what the
 * settings keep (and what both platforms agree on), [maxKbps] the most a step may take. A video offers a few
 * streams (about 50, 70, 128 and up to 160 kbps), so a step takes the best stream within its limit and, when the
 * video has none that low, the smallest one it has.
 */
enum class AudioQuality(val level: Int, private val maxKbps: Int) {
    LOW(0, 0),
    NORMAL(1, 80),
    HIGH(2, 130),
    MAX(3, Int.MAX_VALUE);

    /** The stream of [sources] this step stands for; null when there are none. */
    fun choose(sources: List<AudioSource>): AudioSource? = when (this) {
        MAX -> sources.maxByOrNull { it.bitrateKbps }
        LOW -> sources.minByOrNull { it.bitrateKbps }
        else -> sources.filter { it.bitrateKbps <= maxKbps }.maxByOrNull { it.bitrateKbps }
            ?: sources.minByOrNull { it.bitrateKbps }
    }

    companion object {
        /** The most a step of the bandwidth that is [kbps] can carry, with room to spare: a song streams at the bitrate it has. */
        fun forBandwidth(kbps: Long): AudioQuality {
            val usable = kbps / BANDWIDTH_HEADROOM
            return when {
                usable >= 160 -> MAX
                usable >= 128 -> HIGH
                usable >= 70 -> NORMAL
                else -> LOW
            }
        }

        /**
         * What a song is fetched in: the [setting] is the most, and while the network is [weak] no more than what the
         * [bandwidthKbps] measured can carry (the least stream there is, when nothing was measured).
         */
        fun effective(setting: AudioQuality, weak: Boolean, bandwidthKbps: Long): AudioQuality {
            if (!weak) return setting
            val auto = if (bandwidthKbps > 0) forBandwidth(bandwidthKbps) else LOW
            return if (auto.level < setting.level) auto else setting
        }

        private const val BANDWIDTH_HEADROOM = 1.5

        /** The step for a saved [level]; anything unknown is the best, which is what the app did before there was a choice. */
        fun of(level: Int): AudioQuality = entries.firstOrNull { it.level == level } ?: MAX
    }
}

/**
 * Chooses which audio stream of a video to play or keep. Bytes of a song kept on disk belong to one stream
 * (one itag), and bytes of two streams must never be mixed in one file, so once some are kept that stream
 * has to be used again.
 */
object AudioPicker {

    /** The stream to use and whether it is the [pinned] one, or null for [pinned] when nothing is kept yet. */
    data class Pick(val source: AudioSource, val honoursPin: Boolean)

    /**
     * The stream with the itag [pinned] if the video still offers it, else the one [quality] asks for.
     * [honoursPin] is false when a pin existed but could not be followed: what was kept is of no use then.
     * Null when there are no streams.
     */
    fun pick(sources: List<AudioSource>, pinned: Int?, quality: AudioQuality = AudioQuality.MAX): Pick? {
        if (pinned != null) sources.firstOrNull { it.itag == pinned }?.let { return Pick(it, true) }
        return quality.choose(sources)?.let { Pick(it, pinned == null) }
    }
}
