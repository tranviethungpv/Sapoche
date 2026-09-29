package app.unison.sync

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
 */
@OptIn(ExperimentalCoroutinesApi::class)
fun idleActions(
    inRoom: Flow<Boolean>,
    playing: Flow<Boolean>,
    visible: Flow<Boolean>,
    roomAfterMs: Long,
    serviceAfterMs: Long,
): Flow<IdleAction> =
    combine(inRoom, playing, visible) { room, sound, shown -> Triple(room, sound, shown) }
        .distinctUntilChanged()
        .transformLatest { (room, sound, shown) ->
            if (sound || shown) return@transformLatest
            if (room) {
                delay(roomAfterMs)
                emit(IdleAction.SUSPEND_ROOM)
            } else {
                delay(serviceAfterMs)
                emit(IdleAction.STOP_SERVICE)
            }
        }
