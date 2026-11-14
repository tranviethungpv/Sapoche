package app.sapoche

import app.sapoche.sync.LoadFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Works through the list of songs to download, one at a time. Which songs to take is decided by the list's
 * state: the ones asked for ([LibraryStore.QUEUED]) any time, the ones that wait for Wi-Fi and a charger
 * ([LibraryStore.WAITING]) only when whoever calls knows those are there.
 */
class Downloader(
    private val store: LibraryStore,
    /** Brings the whole song onto the phone and gives back its size in bytes; throws when it cannot. */
    private val fetch: suspend (videoId: String) -> Long,
    private val log: (String) -> Unit = {},
    /** The phone has a working internet connection (not only a network): asked after a song failed, to tell why. */
    private val online: () -> Boolean = { true },
) {
    /** [retryLater]: a song failed but has tries left, so the job should be run again after a while. */
    data class Result(val done: Int, val retryLater: Boolean)

    /**
     * How the run in hand stands: [active] is the song being fetched, null when none is. [total] is what the run has
     * taken so far and what is still to take, so it grows when songs are added meanwhile. A run that is over keeps its
     * numbers (null [active], [total] above zero) until the next run starts; [IDLE] is no run at all.
     */
    data class Batch(val active: String?, val done: Int, val total: Int, val failed: Int) {
        companion object {
            val IDLE = Batch(null, 0, 0, 0)
        }
    }

    private val _progress = MutableStateFlow(Batch.IDLE)
    val progress: StateFlow<Batch> = _progress

    /** Why a song did not come: what to do about it differs. */
    private enum class Why {
        /** YouTube will not give it out, and will not on any try. */
        UNAVAILABLE,

        /** There is no room on the phone for it: no other song will fit either, and trying again is no use until room is made. */
        NO_SPACE,

        /** There is no internet: it is not the song's fault, so no try is used up, and the other songs would fail as well. */
        OFFLINE,

        /** A hiccup of the network or of YouTube's: worth another go in a moment. */
        TRANSIENT,
    }

    private fun why(e: Exception): Why = when {
        LoadFailure.of(e)?.reason == LoadFailure.Reason.UNPLAYABLE -> Why.UNAVAILABLE
        noSpace(e) -> Why.NO_SPACE
        LoadFailure.of(e)?.reason == LoadFailure.Reason.OFFLINE || !online() -> Why.OFFLINE
        else -> Why.TRANSIENT
    }

    /**
     * Brings the song, going on at once with a pause between two or three times when the failure was a hiccup (what was
     * written is kept, so each try goes on from there), before it counts as a failed try of the song.
     */
    private suspend fun fetchPatiently(videoId: String): Long {
        var tried = 0
        while (true) {
            try {
                return fetch(videoId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (tried >= QUICK_RETRY_MS.size || why(e) != Why.TRANSIENT) throw e
                val wait = QUICK_RETRY_MS[tried++]
                log("could not download $videoId (${e.javaClass.simpleName}: ${e.message}), trying again in ${wait}ms")
                delay(wait)
            }
        }
    }

    suspend fun drain(waiting: Boolean): Result {
        val state = if (waiting) LibraryStore.WAITING else LibraryStore.QUEUED
        // A song that failed now is not taken again in this run; its next try is for the next run
        val failedNow = HashSet<String>()
        var done = 0
        var retryLater = false
        // Songs that were put to failed at once without being tried (no room on the phone): they count as failed in the run
        var setAside = 0
        _progress.value = Batch.IDLE
        try {
            while (true) {
                val videoId = store.nextDownload(state, failedNow) ?: break
                _progress.value = Batch(videoId, done, done + failedNow.size + setAside + store.pendingDownloads(state, failedNow), failedNow.size + setAside)
                try {
                    store.finishDownload(videoId, fetchPatiently(videoId))
                    done++
                } catch (e: CancellationException) {
                    throw e // stopped: the song stays on the list as it was
                } catch (e: Exception) {
                    log("could not download $videoId: ${e.javaClass.simpleName}: ${e.message}")
                    when (why(e)) {
                        // A video YouTube will not give out is the same on every try: it says so now instead of after three
                        Why.UNAVAILABLE -> {
                            failedNow += videoId
                            store.markUnavailable(videoId)
                        }
                        // The run stops where it is: every other song would meet the same, and a try used up on each would
                        // leave them all failed for want of a network that comes back. They stay on the list, and the job
                        // is asked to run again
                        Why.OFFLINE -> {
                            log("no internet: the run stops, and no try of the songs is used up")
                            retryLater = true
                            break
                        }
                        // No room: this song and the ones waiting are put to failed at once, so that the person sees it and,
                        // once there is room, tries them again with one button, instead of the job going on and on
                        Why.NO_SPACE -> {
                            log("no room on the phone: the run stops, and the songs on the list are set aside")
                            failedNow += videoId
                            store.failNow(videoId)
                            setAside += store.failAllWaiting(state)
                            break
                        }
                        Why.TRANSIENT -> {
                            failedNow += videoId
                            if (!store.failDownload(videoId)) retryLater = true
                        }
                    }
                }
            }
        } catch (e: CancellationException) {
            _progress.value = Batch.IDLE // a run that was cut short is not a finished one: nothing to announce
            throw e
        }
        val failed = failedNow.size + setAside
        val taken = done + failed
        _progress.value = if (taken == 0) Batch.IDLE else Batch(null, done, taken, failed)
        return Result(done, retryLater)
    }

    companion object {
        /** A hiccup is tried again after these pauses before it counts as a failed try. */
        val QUICK_RETRY_MS = longArrayOf(2_000, 6_000)

        /** The phone has no room: what the file system says, however deep the cache wrapped it. */
        fun noSpace(error: Throwable): Boolean = generateSequence(error) { it.cause }.take(8)
            .any { it.message?.contains("No space left on device", ignoreCase = true) == true || it.message?.contains("ENOSPC") == true }
    }
}
