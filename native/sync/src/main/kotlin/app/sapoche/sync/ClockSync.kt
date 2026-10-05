package app.sapoche.sync

/**
 * Estimates the offset between this device's monotonic clock and the server clock, NTP style.
 *
 * Each ping/pong exchange gives one sample: with c0 the local send time, s1 the server time in the
 * reply and c2 the local receive time, the round trip is c2 - c0 and the server clock read s1 at
 * about local time c0 + rtt/2. The error of one sample is bounded by half its round trip, and grows
 * with its age because the two clocks do not tick at exactly the same rate (phone crystals are off by
 * tens of parts per million). The sample with the smallest bound wins, as NTP does with its dispersion:
 * a fast round trip from five minutes ago no longer beats a slightly slower one from just now.
 *
 * "Local" times must come from one monotonic clock; wall clock changes would corrupt the offset.
 */
class ClockSync(private val windowSize: Int = 12) {

    private class Sample(val offsetMs: Double, val rttMs: Double, val atMs: Long)

    private val samples = ArrayDeque<Sample>()

    @Synchronized
    fun addSample(c0: Long, c2: Long, s1: Long) {
        val rtt = (c2 - c0).toDouble()
        if (rtt < 0) return
        samples.addLast(Sample(offsetMs = s1 - (c0 + rtt / 2), rttMs = rtt, atMs = c2))
        while (samples.size > windowSize) samples.removeFirst()
    }

    @Synchronized
    fun hasSync(): Boolean = samples.isNotEmpty()

    /** Server time minus local time, from the recent sample with the smallest error bound. 0 until the first sample. */
    @Synchronized
    fun offsetMs(): Double = best()?.offsetMs ?: 0.0

    /** Round trip of the sample the offset is based on, or null before the first sample. */
    @Synchronized
    fun bestRttMs(): Double? = best()?.rttMs

    /** Half the round trip, plus what the clocks may have drifted apart since, counted up to the newest sample. */
    private fun best(): Sample? {
        val newest = samples.lastOrNull()?.atMs ?: return null
        return samples.minByOrNull { it.rttMs / 2 + (newest - it.atMs) * DRIFT_PER_MS }
    }

    private companion object {
        /** How fast two clocks may drift apart: 100 parts per million, a phone crystal with margin. */
        const val DRIFT_PER_MS = 100e-6
    }

    fun toServer(localMs: Long): Long = localMs + offsetMs().toLong()

    fun toLocal(serverMs: Long): Long = serverMs - offsetMs().toLong()
}
