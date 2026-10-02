package app.unison.sync

/**
 * Decides when a song counts as heard: after [HEARD_MS] of playing it, or half of it when it is shorter
 * than a minute. Only time spent playing counts, so pauses and buffering do not, and seeking neither adds
 * nor skips anything.
 *
 * A song that is left before it counts, after a few seconds, is reported as skipped.
 *
 * It keeps no clock and no timer. The caller passes the time in and asks [msUntilHeard] how long to wait
 * before calling [check], so it works the same for the personal queue, a room, and a test.
 */
class ListenTracker(
    /** Called once for a song left after a few seconds, before it counted, with its id and length: the person did not want it. */
    private val skipped: (id: String, durationMs: Long) -> Unit = { _, _ -> },
    /** Called once per song, with its id and the length last reported (0 if unknown). */
    private val heard: (id: String, durationMs: Long) -> Unit,
) {
    private var id: String? = null
    private var durationMs = 0L
    private var playedMs = 0L
    private var playingSince: Long? = null
    private var counted = false

    /** A different song is now loaded, or with null nothing is. */
    fun begin(songId: String?, durationMs: Long, now: Long) {
        check(now)
        val leaving = id
        if (leaving != null && !counted && playedMs + (playingSince?.let { now - it } ?: 0) >= SKIPPED_MS) skipped(leaving, this.durationMs)
        id = songId
        this.durationMs = durationMs.coerceAtLeast(0)
        playedMs = 0
        playingSince = null
        counted = false
    }

    /** The song's length became known. */
    fun setDuration(ms: Long) {
        if (ms > 0) durationMs = ms
    }

    fun setPlaying(playing: Boolean, now: Long) {
        if (id == null) return
        check(now)
        val since = playingSince
        if (playing && since == null) {
            playingSince = now
        } else if (!playing && since != null) {
            playedMs += now - since
            playingSince = null
        }
    }

    /** How long until the song counts if it keeps playing, or null when that is not going to happen. */
    fun msUntilHeard(now: Long): Long? {
        val since = playingSince ?: return null
        if (id == null || counted) return null
        return (threshold() - playedMs - (now - since)).coerceAtLeast(0)
    }

    /** Counts the song if it has been played long enough by [now]. */
    fun check(now: Long) {
        val current = id ?: return
        if (counted) return
        val total = playedMs + (playingSince?.let { now - it } ?: 0)
        if (total < threshold()) return
        counted = true
        heard(current, durationMs)
    }

    private fun threshold() = if (durationMs > 0) minOf(HEARD_MS, durationMs / 2) else HEARD_MS

    companion object {
        const val HEARD_MS = 30_000L

        /** A song left after at least this long, and before it counted, was skipped; less is a change of mind or a glitch. */
        const val SKIPPED_MS = 3_000L
    }
}
