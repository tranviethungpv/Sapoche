package app.sapoche

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.work.ForegroundInfo

/**
 * What the person sees of a run of downloads outside the app: a quiet notification that says which song of how many,
 * and, when the run ends while the app is not in front, one that says how it went. Nothing here asks for leave to
 * show notifications: without it the notices are simply not shown, and the app itself tells the same.
 */
class DownloadNotifier(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    private fun builder(): Notification.Builder {
        if (Build.VERSION.SDK_INT >= 26) {
            // Both languages: the name is kept by the system, which cannot follow the app's language
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Downloads · Tải về", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(
            context,
            0,
            context.packageManager.getLaunchIntentForPackage(context.packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(context)
        return builder.setSmallIcon(R.drawable.ic_notification).setContentIntent(open)
    }

    /** The notification of the run in hand, to be shown by the job that does it: [title] is the song being fetched. */
    fun progress(batch: Downloader.Batch, title: String?): ForegroundInfo {
        val vi = SapocheApp.language.value == "vi"
        val place = (batch.done + batch.failed + 1).coerceIn(1, maxOf(batch.total, 1))
        val head = if (vi) "Đang tải $place/${batch.total}" else "Downloading $place of ${batch.total}"
        val notification = builder()
            .setContentTitle(head)
            .setContentText(title)
            .setProgress(batch.total, batch.done + batch.failed, false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
        return if (Build.VERSION.SDK_INT >= 29) {
            ForegroundInfo(PROGRESS_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(PROGRESS_ID, notification)
        }
    }

    /** The run is over: how it went. */
    fun finished(batch: Downloader.Batch) {
        if (!manager.areNotificationsEnabled()) return
        val vi = SapocheApp.language.value == "vi"
        val text = when {
            batch.failed == 0 -> if (vi) "Đã tải xong ${batch.done} bài" else if (batch.done == 1) "Downloaded 1 song" else "Downloaded ${batch.done} songs"
            else -> if (vi) "Đã tải ${batch.done} bài, ${batch.failed} bài không tải được" else "Downloaded ${batch.done}, ${batch.failed} could not be downloaded"
        }
        manager.notify(DONE_ID, builder().setContentTitle(text).setAutoCancel(true).build())
    }

    private companion object {
        const val CHANNEL = "downloads"
        const val PROGRESS_ID = 4108
        const val DONE_ID = 4109
    }
}
