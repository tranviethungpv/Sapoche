package app.sapoche.sync

/**
 * Estimates the offset between this device's monotonic clock and the server clock, NTP style.
 *
 * Each ping/pong exchange gives one sample: with c0 the local send time, s1 the server time in the
 * reply and c2 the local receive time, the round trip is c2 - c0 and the server clock read s1 at
 * about local time c0 + rtt/2. The sample with the smallest round trip is the most trustworthy,
 * because the error of the estimate is bounded by half the round trip.
 *
 * "Local" times must come from one monotonic clock; wall clock changes would corrupt the offset.
 */
class ClockSync(private val windowSize: Int = 12) {

    private class Sample(val offsetMs: Double, val rttMs: Double)

    private val samples = ArrayDeque<Sample>()

    @Synchronized
    fun addSample(c0: Long, c2: Long, s1: Long) {
        val rtt = (c2 - c0).toDouble()
        if (rtt < 0) return
        samples.addLast(Sample(offsetMs = s1 - (c0 + rtt / 2), rttMs = rtt))
        while (samples.size > windowSize) samples.removeFirst()
    }

    @Synchronized
    fun hasSync(): Boolean = samples.isNotEmpty()

    /** Server time minus local time, from the lowest-latency recent sample. 0 until the first sample. */
    @Synchronized
    fun offsetMs(): Double = samples.minByOrNull { it.rttMs }?.offsetMs ?: 0.0

    /** Round trip of the sample the offset is based on, or null before the first sample. */
    @Synchronized
    fun bestRttMs(): Double? = samples.minOfOrNull { it.rttMs }

    fun toServer(localMs: Long): Long = localMs + offsetMs().toLong()

    fun toLocal(serverMs: Long): Long = serverMs - offsetMs().toLong()
}
