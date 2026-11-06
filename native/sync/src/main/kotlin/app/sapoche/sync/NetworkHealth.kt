package app.sapoche.sync

/** What a device that fell behind the room does about it while its network is weak, see [NetworkHealth.catchUp]. */
sealed interface CatchUp {
    /** Keep playing at normal speed: the data to go faster is not there. */
    data object Wait : CatchUp

    /** Close the gap by speeding up a little: it is small and the buffer can pay for it. */
    data class Speed(val factor: Float) : CatchUp

    /** One seek to where the room is: the buffer holds that place. */
    data object SeekInBuffer : CatchUp

    /** Too far behind to wait for: pause, load the room's place, and start there at an agreed moment. */
    data object Jump : CatchUp
}

/**
 * Tells a network that is slow or comes and goes from a good one, from the stalls a player reports, and keeps what the
 * session learned about it. Pure logic on the caller's monotonic clock; one per session ([GroupSession], [LocalSession]).
 *
 * A good network never gets here: the first stall that is not the player's own doing turns [weak] on, and a minute without
 * another one, with a full buffer ahead, turns it off.
 */
class NetworkHealth {
    var weak = false
        private set(value) {
            if (field == value) return
            field = value
            onChange?.invoke(value)
        }

    /** Called when [weak] turns on or off, on the thread that changed it. */
    var onChange: ((Boolean) -> Unit)? = null

    /** How long loading a place the player does not have takes, learned from jumps and loads. Aims the next start. */
    var loadMs = DEFAULT_LOAD_MS
        private set

    private var lastStallEndMs = 0L

    /** The player stalled, and played again at [nowMs]. Returns true when this is what turned weak mode on. */
    fun onStall(nowMs: Long): Boolean {
        lastStallEndMs = nowMs
        val turned = !weak
        weak = true
        return turned
    }

    /** A jump to a place the player had to load took [tookMs] against the lead it was given. */
    fun learnLoad(tookMs: Long) {
        loadMs = ((loadMs + tookMs * LOAD_MARGIN) / 2).toLong().coerceIn(MIN_LOAD_MS, MAX_LOAD_MS)
    }

    /** A jump did not make its moment at [nowMs]: ask for more time next, and count it as a stall for how long the network stays weak. */
    fun onJumpMissed(nowMs: Long, tookMs: Long) {
        lastStallEndMs = nowMs
        weak = true
        loadMs = (maxOf(loadMs, tookMs) * 2).coerceIn(MIN_LOAD_MS, MAX_LOAD_MS)
    }

    /** Whether [nowMs] is late enough in a calm spell, with [aheadMs] of song buffered, to go back to the plain rules. */
    fun tick(nowMs: Long, aheadMs: Long, fullyLoaded: Boolean): Boolean {
        if (!weak) return false
        if (nowMs - lastStallEndMs < QUIET_MS) return false
        if (aheadMs < RECOVERED_AHEAD_MS && !fullyLoaded) return false
        weak = false
        loadMs = DEFAULT_LOAD_MS
        return true
    }

    /**
     * How a device [lagMs] behind the room (positive) catches up while the network is weak, with [aheadMs] of the song
     * already loaded ahead of its position.
     */
    fun catchUp(lagMs: Long, aheadMs: Long): CatchUp = when {
        lagMs > MAX_LAG_MS -> CatchUp.Jump
        lagMs < SPEED_LAG_MS && aheadMs >= SPEED_AHEAD_MS -> CatchUp.Speed(1.03f)
        aheadMs >= lagMs + SEEK_BUFFER_MS -> CatchUp.SeekInBuffer
        else -> CatchUp.Wait
    }

    companion object {
        const val DEFAULT_LOAD_MS = 3_000L
        const val MIN_LOAD_MS = 2_000L
        const val MAX_LOAD_MS = 10_000L
        private const val LOAD_MARGIN = 1.5

        /** No stall for this long, and a buffer of [RECOVERED_AHEAD_MS], and the network counts as good again. */
        const val QUIET_MS = 60_000L
        const val RECOVERED_AHEAD_MS = 30_000L

        /** A device may run this far behind the room before it jumps, rather than stall again to close the gap. */
        const val MAX_LAG_MS = 15_000L
        const val SEEK_BUFFER_MS = 10_000L
        const val SPEED_LAG_MS = 1_500L
        const val SPEED_AHEAD_MS = 20_000L

        /** At most one seek this often while weak; a seek that is followed by a stall doubles it. */
        const val SEEK_GAP_MS = 20_000L
    }
}
