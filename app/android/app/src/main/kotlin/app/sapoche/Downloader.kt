package app.sapoche

import kotlinx.coroutines.CancellationException

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

    suspend fun drain(waiting: Boolean): Result {
        val state = if (waiting) LibraryStore.WAITING else LibraryStore.QUEUED
        // A song that failed now is not taken again in this run; its next try is for the next run
        val failedNow = HashSet<String>()
        var done = 0
        var retryLater = false
        while (true) {
            val videoId = store.nextDownload(state, failedNow) ?: break
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
        return Result(done, retryLater)
    }
}
