package app.sapoche

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Tells the person a new version waits for their word, when the system asks them to confirm the install of an update that
 * went on in the background: its dialog must not jump up over whatever they are doing, so it waits behind a notification.
 */
class UpdateNotifier(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    /** [confirm] is the system's own question about the install; touching the notification opens it. */
    fun offer(version: String, confirm: Intent) {
        if (!manager.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= 26) {
            // Both languages: the name is kept by the system, which cannot follow the app's language
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Updates · Cập nhật", NotificationManager.IMPORTANCE_LOW))
        }
        val vi = SapocheApp.language.value == "vi"
        val open = PendingIntent.getActivity(
            context,
            0,
            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(context)
        manager.notify(
            ID,
            builder
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(if (vi) "Sapoche $version đã sẵn sàng" else "Sapoche $version is ready")
                .setContentText(if (vi) "Chạm để cài bản mới" else "Tap to install the new version")
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }

    fun clear() = manager.cancel(ID)

    private companion object {
        const val CHANNEL = "updates"
        const val ID = 4107
    }
}
