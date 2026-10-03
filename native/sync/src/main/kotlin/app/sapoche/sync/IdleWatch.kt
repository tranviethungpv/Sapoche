package app.sapoche.sync

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.transformLatest

/** What to let go of when nobody has been listening or looking for a while. */
enum class IdleAction {
    /** In a room: close the connection. Nothing is forgotten; it comes back when someone looks or presses play. */
    SUSPEND_ROOM,

    /** Outside a room: stop the whole playback service. */
    STOP_SERVICE,
}

/**
 * Says when nobody is listening ([playing] false) or looking ([visible] false) for long enough that
 * something which costs battery should go: after [roomAfterMs] in a room its connection, whose pings keep
 * the radio awake all day, and after [serviceAfterMs] outside a room the service itself. Anyone playing or
 * looking again cancels the wait, and a wait that ended is not repeated until something changes.
 *
 * [now] is a clock that keeps counting while the device sleeps (`SystemClock.elapsedRealtime`). A coroutine
 * `delay` does not: it counts only the time the device is awake, and a phone in a pocket sleeps almost all
 * of the time, so a single long `delay` would take hours. Instead the wait is made of short delays of
 * [checkEveryMs], after each of which the clock is asked how long it has really been.
 */
@OptIn(ExperimentalCoroutinesApi::class)
fun idleActions(
    inRoom: Flow<Boolean>,
    playing: Flow<Boolean>,
    visible: Flow<Boolean>,
    roomAfterMs: Long,
    serviceAfterMs: Long,
    now: () -> Long,
    checkEveryMs: Long = 30_000,
): Flow<IdleAction> =
    combine(inRoom, playing, visible) { room, sound, shown -> Triple(room, sound, shown) }
        .distinctUntilChanged()
        .transformLatest { (room, sound, shown) ->
            if (sound || shown) return@transformLatest
            val quietFor = now()
            val wait = if (room) roomAfterMs else serviceAfterMs
            while (now() - quietFor < wait) delay(minOf(checkEveryMs, wait - (now() - quietFor)))
            emit(if (room) IdleAction.SUSPEND_ROOM else IdleAction.STOP_SERVICE)
        }
