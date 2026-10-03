package app.sapoche.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** What the sleep timer is set to. */
sealed interface Sleep {
    data object Off : Sleep

    /** Stops the music at [endsAtMs] (wall clock, so the UI can show the hour). */
    data class At(val endsAtMs: Long) : Sleep

    /** Stops the music when the song that plays now is over. */
    data object SongEnd : Sleep
}

/**
 * Stops the music after a while so that the person can fall asleep to it. The volume goes down over
 * the last [FADE_MS] so that it does not end with a jolt.
 *
 * [stop] pauses this device; [fade] sets the volume (1 is full) and [pauseAtSongEnd] asks the player
 * to pause when the song is over. The host calls [songEnded] once that happened.
 */
class SleepTimer(
    private val scope: CoroutineScope,
    private val wallClock: () -> Long,
    private val stop: () -> Unit,
    private val fade: (Float) -> Unit,
    private val pauseAtSongEnd: (Boolean) -> Unit,
) {
    private val _state = MutableStateFlow<Sleep>(Sleep.Off)
    val state: StateFlow<Sleep> = _state.asStateFlow()

    private var job: Job? = null

    /** Stops in [minutes], replacing what was set before. */
    fun startIn(minutes: Int) {
        val ms = minutes.coerceIn(1, MAX_MINUTES) * 60_000L
        reset()
        _state.value = Sleep.At(wallClock() + ms)
        job = scope.launch {
            delay((ms - FADE_MS).coerceAtLeast(0))
            var left = minOf(ms, FADE_MS)
            while (left > 0) {
                fade(left.toFloat() / FADE_MS)
                val step = minOf(left, FADE_STEP_MS)
                delay(step)
                left -= step
            }
            fire()
        }
    }

    /** Stops at the end of the song playing now. */
    fun startAtSongEnd() {
        reset()
        _state.value = Sleep.SongEnd
        pauseAtSongEnd(true)
    }

    fun cancel() {
        reset()
        _state.value = Sleep.Off
    }

    /** The player paused at the end of a song, or the queue ran out. */
    fun songEnded() {
        if (_state.value == Sleep.SongEnd) fire()
    }

    private fun fire() {
        // Silence first: the volume only comes back once the player is paused
        stop()
        reset()
        _state.value = Sleep.Off
    }

    /** Undoes what the timer did to the player. */
    private fun reset() {
        job?.cancel()
        job = null
        fade(1f)
        pauseAtSongEnd(false)
    }

    companion object {
        const val FADE_MS = 15_000L
        const val FADE_STEP_MS = 500L
        const val MAX_MINUTES = 12 * 60
    }
}
