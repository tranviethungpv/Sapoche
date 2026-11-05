package app.sapoche.core

import kotlin.math.pow

/**
 * Evens out how loud songs are, as YouTube does: a song that is above its reference level (-14 LKFS; `loudnessDb` of a
 * stream says by how much) is played quieter by that much, one that is below it is left as it is. A player's volume
 * only goes down from full, so a quiet song cannot be raised without a limiter to keep it from distorting.
 */
object Loudness {
    /** The most a song is turned down, in dB, whatever its stream claims. */
    const val MAX_CUT_DB = 12.0

    /** The volume factor (0..1) for a song [db] above the reference level; 1 when it is not known or not above. */
    fun gain(db: Double?): Float {
        if (db == null || db.isNaN() || db <= 0.0) return 1f
        return 10.0.pow(-minOf(db, MAX_CUT_DB) / 20.0).toFloat()
    }
}
