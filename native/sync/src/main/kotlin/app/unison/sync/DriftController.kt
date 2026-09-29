package app.unison.sync

import kotlin.math.abs

sealed interface DriftAction {
    /** Nothing to change. */
    data object None : DriftAction

    /** Change the playback speed; 1.0 restores normal playback. */
    data class SetSpeed(val factor: Float) : DriftAction

    /** Too far off to correct smoothly: jump to the expected position. */
    data object Seek : DriftAction
}

/**
 * Decides how to pull a player back in line with the room.
 *
 * Drift is player position minus expected position: positive means this device is ahead and
 * must slow down, negative means it is behind and must speed up. Small drift is corrected by
 * nudging the speed (inaudible), large drift by seeking. Correction stops when the drift is
 * nearly gone, with a gap between the start and stop thresholds so it does not flutter.
 */
class DriftController(
    private val deadbandMs: Long = 40,
    private val settleMs: Long = 15,
    val seekThresholdMs: Long = 400,
    private val speedDelta: Float = 0.03f,
) {
    /** -1 while slowing down, +1 while speeding up, 0 at normal speed. */
    private var correcting = 0

    fun decide(driftMs: Long): DriftAction {
        val size = abs(driftMs)

        if (size > seekThresholdMs) {
            // The caller restores normal speed together with the seek
            correcting = 0
            return DriftAction.Seek
        }

        if (correcting == 0) {
            if (size <= deadbandMs) return DriftAction.None
            correcting = if (driftMs > 0) -1 else 1
            return DriftAction.SetSpeed(1f + correcting * speedDelta)
        }

        // Currently correcting: stop when close enough or when we overshot to the other side
        val overshot = (correcting == -1 && driftMs <= 0) || (correcting == 1 && driftMs >= 0)
        if (size <= settleMs || overshot) {
            correcting = 0
            return DriftAction.SetSpeed(1f)
        }
        return DriftAction.None
    }

    /** Forget any correction in progress, e.g. after the player was reset to normal speed. */
    fun reset() {
        correcting = 0
    }
}

/**
 * Smooths the drift readings before they reach the [DriftController].
 *
 * Player position readings are noisy: on the test phones raw drift showed a sawtooth of about
 * 200ms with a 3-4 second period even with no correction at all. Acting on single readings
 * would chase that noise, so the filter averages a window of readings. Because a speed change
 * moves the position on purpose, each reading is first stripped of the correction applied so
 * far; the average of those is the drift the device would have had without any correction,
 * and adding the current correction back gives its drift right now.
 */
class DriftFilter(private val size: Int = 8, private val minSamplesForLargeDrift: Int = 3) {
    private val samples = ArrayDeque<Double>()

    /** Total shift, in ms, that speed changes have applied to the position. */
    private var correctionMs = 0.0
    private var speed = 1f
    private var lastMs = 0L

    val count: Int get() = samples.size

    /** The window is full enough to trust for a small correction. */
    val isFull: Boolean get() = samples.size >= size

    /** The window has enough readings to confirm a large drift. */
    val hasLargeDriftEvidence: Boolean get() = samples.size >= minSamplesForLargeDrift

    private fun advance(nowMs: Long) {
        correctionMs += (speed - 1f) * (nowMs - lastMs)
        lastMs = nowMs
    }

    fun add(nowMs: Long, driftMs: Long) {
        advance(nowMs)
        samples.addLast(driftMs - correctionMs)
        if (samples.size > size) samples.removeFirst()
    }

    /** Mean drift the device would have without any correction, or null with no readings. */
    fun uncorrectedMean(): Double? = if (samples.isEmpty()) null else samples.average()

    /** Best estimate of the drift at [nowMs], or null when there are no readings. */
    fun estimate(nowMs: Long): Long? {
        if (samples.isEmpty()) return null
        advance(nowMs)
        return (samples.average() + correctionMs).toLong()
    }

    /** Record a speed change so later readings are compensated correctly. */
    fun setSpeed(nowMs: Long, newSpeed: Float) {
        advance(nowMs)
        speed = newSpeed
    }

    /** Forget everything, e.g. after a seek moved the position discontinuously. */
    fun reset(nowMs: Long, newSpeed: Float = 1f) {
        samples.clear()
        correctionMs = 0.0
        speed = newSpeed
        lastMs = nowMs
    }
}
