package app.sapoche

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit

/**
 * Downloads the songs on the list as a job, so that it goes on with the network while the app is in the
 * background, which a bare coroutine does not. There are two kinds: songs the person asked for go on any
 * network, liked songs go by themselves only on Wi-Fi with the phone charging.
 */
class DownloadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val waiting = inputData.getBoolean(KEY_WAITING, false)
        if (waiting) {
            // Liked songs saved by themselves: not while the phone is warm, they can wait for it to cool
            if (SapocheApp.heat.calm.value) {
                EventLog.d("download", "put off: the phone is warm or saving power")
                return Result.retry()
            }
            if (!applicationContext.getSharedPreferences("sapoche", Context.MODE_PRIVATE).getBoolean(KEY_AUTO, false)) {
                return Result.success()
            }
            SapocheApp.library.requestDownloads(SapocheApp.library.likedToDownload(), waiting = true)
        }
        val result = if (waiting) SapocheApp.downloader.drain(true) else drainShowingProgress()
        EventLog.d("download", "job done: ${result.done} songs${if (result.retryLater) ", some to try again" else ""}")
        return if (result.retryLater) Result.retry() else Result.success()
    }

    /**
     * Songs the person asked for are fetched as a foreground job with a notification that says which song of how many.
     * That also lifts the ten minutes a plain job is given. Liked songs saved by themselves stay quiet (and run when the
     * app is in the background, where a foreground job cannot be started).
     */
    private suspend fun drainShowingProgress(): Downloader.Result = coroutineScope {
        val notifier = DownloadNotifier(applicationContext)
        var foreground = true
        val watcher = launch {
            SapocheApp.downloader.progress.collect { batch ->
                val active = batch.active
                if (active == null || !foreground) return@collect
                val title = SapocheApp.library.downloads().firstOrNull { it.track.videoId == active }?.track?.title
                try {
                    setForeground(notifier.progress(batch, title))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: IllegalStateException) {
                    // The system does not let a job in the background become a foreground one: it goes on without the notice
                    foreground = false
                    EventLog.d("download", "no notification for the run: ${e.javaClass.simpleName}")
                } catch (e: SecurityException) {
                    foreground = false
                    EventLog.d("download", "no notification for the run: ${e.javaClass.simpleName}")
                }
            }
        }
        val result = try {
            SapocheApp.downloader.drain(false)
        } finally {
            watcher.cancel()
        }
        val batch = SapocheApp.downloader.progress.value
        if (batch.active == null && batch.total > 0 && !SapocheApp.uiVisible.value) notifier.finished(batch)
        result
    }

    companion object {
        const val KEY_AUTO = "auto_download"
        private const val KEY_WAITING = "waiting"

        /** Starts the job for asked-for songs ([waiting] false) or for liked songs that wait for Wi-Fi and a charger. */
        fun enqueue(context: Context, waiting: Boolean) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(if (waiting) NetworkType.UNMETERED else NetworkType.CONNECTED)
                .setRequiresCharging(waiting)
                .build()
            val request = OneTimeWorkRequestBuilder<DownloadWorker>()
                .setConstraints(constraints)
                .setInputData(workDataOf(KEY_WAITING to waiting))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
                .build()
            // Asked-for songs: appended, so a job that is just finishing is followed by one that sees what was added
            // meanwhile. Liked songs: one waiting job is enough, it looks at the likes when it runs.
            WorkManager.getInstance(context).enqueueUniqueWork(
                if (waiting) "download-waiting" else "download-queued",
                if (waiting) ExistingWorkPolicy.KEEP else ExistingWorkPolicy.APPEND_OR_REPLACE,
                request,
            )
        }

        fun cancelWaiting(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork("download-waiting")
        }
    }
}
