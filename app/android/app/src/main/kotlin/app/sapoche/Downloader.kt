package app.sapoche

import kotlinx.coroutines.CancellationException
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

    suspend fun drain(waiting: Boolean): Result {
        val state = if (waiting) LibraryStore.WAITING else LibraryStore.QUEUED
        // A song that failed now is not taken again in this run; its next try is for the next run
        val failedNow = HashSet<String>()
        var done = 0
        var retryLater = false
        _progress.value = Batch.IDLE
        try {
            while (true) {
                val videoId = store.nextDownload(state, failedNow) ?: break
                _progress.value = Batch(videoId, done, done + failedNow.size + store.pendingDownloads(state, failedNow), failedNow.size)
                try {
                    store.finishDownload(videoId, fetch(videoId))
                    done++
                } catch (e: CancellationException) {
                    throw e // stopped: the song stays on the list as it was
                } catch (e: Exception) {
                    log("could not download $videoId: ${e.javaClass.simpleName}: ${e.message}")
                    failedNow += videoId
                    if (!store.failDownload(videoId)) retryLater = true
                }
            }
        } catch (e: CancellationException) {
            _progress.value = Batch.IDLE // a run that was cut short is not a finished one: nothing to announce
            throw e
        }
        val taken = done + failedNow.size
        _progress.value = if (taken == 0) Batch.IDLE else Batch(null, done, taken, failedNow.size)
        return Result(done, retryLater)
    }
}
