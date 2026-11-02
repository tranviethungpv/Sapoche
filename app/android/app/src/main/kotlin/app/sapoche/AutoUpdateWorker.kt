package app.sapoche

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/**
 * Once a day, on Wi-Fi and with the battery not low: looks for a newer release, fetches it, and installs it when that
 * costs nobody anything, as a store does. Installing stops the app, so it waits for a moment when nobody looks at the
 * screen, nothing plays and no room is joined, and it tries a release only once: after that the sheet in the app and
 * the notification are what is left to the person.
 */
class AutoUpdateWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val updater = SapocheApp.updater
        if (!updater.auto) return Result.success()
        updater.refresh()
        val release = updater.state.value.release
        if (updater.state.value.phase != UpdateState.Phase.READY || release == null) return Result.success()
        if (updater.triedAuto(release)) return Result.success()
        if (!quiet()) {
            EventLog.d("update", "ready, but the phone is in use: put off")
            return Result.retry()
        }
        EventLog.d("update", "installing ${release.versionName} by itself")
        updater.markTriedAuto(release)
        updater.install()
        return Result.success()
    }

    /** Nobody looks at the app, nothing plays and no room is joined. The player is read on the main thread. */
    private suspend fun quiet(): Boolean = withContext(Dispatchers.Main) {
        if (SapocheApp.uiVisible.value) return@withContext false
        val group = SapocheApp.group.value ?: return@withContext true
        !group.playerInfo().playing && group.view.value.roomCode == null
    }

    companion object {
        private const val NAME = "auto-update"

        /** Keeps the job that is there: asking again on every start of the app must not push its time back. */
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<AutoUpdateWorker>(24, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.UNMETERED)
                        .setRequiresBatteryNotLow(true)
                        .build(),
                )
                .setBackoffCriteria(BackoffPolicy.LINEAR, 1, TimeUnit.HOURS)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(NAME)
        }
    }
}
