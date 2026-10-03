package app.sapoche.sync

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals

@OptIn(ExperimentalCoroutinesApi::class)
class IdleWatchTest {

    private val room = 20 * 60_000L
    private val service = 15 * 60_000L

    private class Inputs {
        val inRoom = MutableStateFlow(false)
        val playing = MutableStateFlow(false)
        val visible = MutableStateFlow(false)
    }

    /** Time the device spent asleep: the wall clock ran, but no coroutine delay did. */
    private var asleepMs = 0L

    private fun TestScope.watch(inputs: Inputs): List<IdleAction> {
        val actions = mutableListOf<IdleAction>()
        backgroundScope.launch {
            idleActions(inputs.inRoom, inputs.playing, inputs.visible, room, service, now = { currentTime + asleepMs })
                .collect { actions += it }
        }
        runCurrent()
        return actions
    }

    private fun TestScope.minutes(n: Long) {
        advanceTimeBy(n * 60_000)
        runCurrent()
    }

    @Test
    fun `outside a room the service stops after fifteen quiet minutes`() = runTest {
        val actions = watch(Inputs())
        minutes(14)
        assertEquals(emptyList(), actions)
        minutes(2)
        assertEquals(listOf(IdleAction.STOP_SERVICE), actions)
    }

    @Test
    fun `in a room the connection is let go of after twenty quiet minutes, not the service`() = runTest {
        val inputs = Inputs().apply { inRoom.value = true }
        val actions = watch(inputs)
        minutes(19)
        assertEquals(emptyList(), actions)
        minutes(2)
        assertEquals(listOf(IdleAction.SUSPEND_ROOM), actions)
    }

    @Test
    fun `nothing happens while music plays or the screen is being looked at`() = runTest {
        val inputs = Inputs().apply { playing.value = true }
        val actions = watch(inputs)
        minutes(60)
        inputs.playing.value = false
        inputs.visible.value = true
        minutes(60)
        assertEquals(emptyList(), actions)
    }

    @Test
    fun `playing or looking again starts the count over`() = runTest {
        val inputs = Inputs()
        val actions = watch(inputs)
        minutes(10)
        inputs.visible.value = true
        minutes(30)
        inputs.visible.value = false
        minutes(10)
        assertEquals(emptyList(), actions, "ten minutes since the last look is not fifteen")
        minutes(6)
        assertEquals(listOf(IdleAction.STOP_SERVICE), actions)
    }

    @Test
    fun `time spent asleep counts, at the first moment the device is awake again`() = runTest {
        asleepMs = 0
        val actions = watch(Inputs())
        minutes(2)
        asleepMs += 20 * 60_000 // the phone slept for twenty minutes: no delay ran, but the wall clock did
        assertEquals(emptyList(), actions, "nothing runs while asleep")
        minutes(1)
        assertEquals(listOf(IdleAction.STOP_SERVICE), actions, "the next check after waking sees how long it has been")
    }

    @Test
    fun `a stop is not repeated while nothing changes`() = runTest {
        val actions = watch(Inputs())
        minutes(120)
        assertEquals(1, actions.size)
    }

    @Test
    fun `joining a room while quiet switches to the room's longer wait`() = runTest {
        val inputs = Inputs()
        val actions = watch(inputs)
        minutes(10)
        inputs.inRoom.value = true
        minutes(15)
        assertEquals(emptyList(), actions, "the wait began again in the room, and is twenty minutes")
        minutes(6)
        assertEquals(listOf(IdleAction.SUSPEND_ROOM), actions)
    }
}
