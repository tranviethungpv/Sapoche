package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NetworkHealthTest {
    @Test
    fun `a good network is never weak, and the first stall makes it weak`() {
        val health = NetworkHealth()
        assertFalse(health.weak)
        assertTrue(health.onStall(10_000))
        assertTrue(health.weak)
        assertFalse(health.onStall(12_000), "already weak: not newly so")
    }

    @Test
    fun `weak ends after a quiet minute with a full buffer, not before`() {
        val health = NetworkHealth()
        health.onStall(10_000)
        assertFalse(health.tick(69_000, aheadMs = 40_000, fullyLoaded = false), "under a minute")
        assertFalse(health.tick(71_000, aheadMs = 10_000, fullyLoaded = false), "the buffer is thin")
        assertTrue(health.tick(71_000, aheadMs = 10_000, fullyLoaded = true), "the whole song is there")
        assertFalse(health.weak)

        health.onStall(80_000)
        assertTrue(health.tick(141_000, aheadMs = 30_000, fullyLoaded = false))
    }

    @Test
    fun `behind the room, the way to catch up depends on the lag and the buffer`() {
        val health = NetworkHealth()
        assertEquals(CatchUp.Jump, health.catchUp(lagMs = 16_000, aheadMs = 60_000))
        assertEquals(CatchUp.SeekInBuffer, health.catchUp(lagMs = 5_000, aheadMs = 15_000))
        assertEquals(CatchUp.SeekInBuffer, health.catchUp(lagMs = 1_000, aheadMs = 11_000))
        assertEquals(CatchUp.Speed(1.03f), health.catchUp(lagMs = 1_000, aheadMs = 20_000))
        assertEquals(CatchUp.Wait, health.catchUp(lagMs = 5_000, aheadMs = 8_000))
        assertEquals(CatchUp.Wait, health.catchUp(lagMs = 1_000, aheadMs = 5_000), "a thin buffer does not pay for speeding up")
    }

    @Test
    fun `a missed jump counts as a stall, so weak lasts a quiet minute from it`() {
        val health = NetworkHealth()
        health.onJumpMissed(nowMs = 10_000, tookMs = 4_000)
        assertTrue(health.weak)
        assertFalse(health.tick(20_000, aheadMs = 60_000, fullyLoaded = true), "too soon after the miss")
        assertTrue(health.tick(71_000, aheadMs = 60_000, fullyLoaded = true))
    }

    @Test
    fun `the time asked for a jump follows what loading took, within limits`() {
        val health = NetworkHealth()
        assertEquals(3_000, health.loadMs)
        health.onJumpMissed(nowMs = 1_000, tookMs = 4_000)
        assertEquals(8_000, health.loadMs)
        health.onJumpMissed(nowMs = 2_000, tookMs = 9_000)
        assertEquals(NetworkHealth.MAX_LOAD_MS, health.loadMs)
        repeat(10) { health.learnLoad(tookMs = 200) }
        assertEquals(NetworkHealth.MIN_LOAD_MS, health.loadMs)
    }
}
