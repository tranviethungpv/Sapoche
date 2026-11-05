package app.sapoche.core

import kotlin.test.Test
import kotlin.test.assertEquals

class LoudnessTest {

    /** The same table is in `LoudnessTests.swift`: the two platforms must turn a song down by the same amount. */
    private val table = listOf(
        null to 1.0,
        Double.NaN to 1.0,
        -3.0 to 1.0,
        0.0 to 1.0,
        0.99 to 0.8923,
        3.0 to 0.7079,
        6.55 to 0.4704,
        12.0 to 0.2512,
        30.0 to 0.2512,
    )

    @Test
    fun `a song above the reference level is turned down by that much, the rest is left alone`() {
        for ((db, factor) in table) assertEquals(factor.toFloat(), Loudness.gain(db), 0.0001f, "gain of $db dB")
    }
}
