package app.sapoche

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import app.sapoche.sync.ChatNotice
import app.sapoche.sync.ChatNotices
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * Tells the person of the chat while the app is not in front: a notification for a message, an answer to one of theirs,
 * or a reaction to one of theirs. It only has what the room connection hears, so it is silent once the connection is
 * let go of for being idle. Off until the person turns it on, and quiet for the rooms they keep quiet.
 */
class ChatNotifier(private val context: Context) {
    private val prefs = context.getSharedPreferences("sapoche", Context.MODE_PRIVATE)
    private val manager = context.getSystemService(NotificationManager::class.java)

    /** What each room's notification says so far, newest last. */
    private val lines = HashMap<String, ArrayDeque<String>>()

    init {
        // The call goes to the system and took about 60 ms of the start of the app (measured), which nobody waits for:
        // the channel only has to be there before the first notification and before the system asks for leave to post
        if (Build.VERSION.SDK_INT >= 26) {
            thread(name = "chat-channel", isDaemon = true) {
                manager.createNotificationChannel(
                    // Both languages: the name is kept by the system, which cannot follow the app's language
                    NotificationChannel(CHANNEL, "Chat · Tin nhắn", NotificationManager.IMPORTANCE_DEFAULT),
                )
            }
        }
    }

    private val enabled get() = prefs.getBoolean(KEY_ENABLED, false)

    var preview: Boolean
        get() = prefs.getBoolean(KEY_PREVIEW, true)
        set(value) = prefs.edit().putBoolean(KEY_PREVIEW, value).apply()

    /** The phone lets this app show notifications. */
    fun granted(): Boolean = manager.areNotificationsEnabled()

    /** Turns the notices on or off; the system's leave has to be asked for before, with [markRefused] when it is not given. */
    fun setEnabled(on: Boolean) {
        prefs.edit().putBoolean(KEY_ENABLED, on).apply()
        if (!on) clear()
    }

    fun markRefused(refused: Boolean) = prefs.edit().putBoolean(KEY_REFUSED, refused).apply()

    /** How things stand, as the screen takes it (see NotificationInfo.fromMap). */
    fun info(): Map<String, Any?> {
        val granted = granted()
        // From Android 13 the first ask opens a dialog; after a refusal the system does not open it again
        val permission = when {
            granted -> "granted"
            Build.VERSION.SDK_INT >= 33 && !prefs.getBoolean(KEY_REFUSED, false) -> "undecided"
            else -> "denied"
        }
        return mapOf("supported" to true, "permission" to permission, "enabled" to (enabled && granted), "preview" to preview, "mutes" to mutes())
    }

    /** The rooms kept quiet and until when (milliseconds since 1970); those whose time has passed are let go. */
    fun mutes(): Map<String, Long> {
        val now = System.currentTimeMillis()
        val saved = runCatching { JSONObject(prefs.getString(KEY_MUTES, null) ?: "{}") }.getOrDefault(JSONObject())
        return saved.keys().asSequence().associateWith { saved.getLong(it) }.filterValues { it > now }
    }

    /** Keeps room [code] quiet until [until], or with null makes it loud again. */
    fun mute(code: String, until: Long?) {
        val saved = JSONObject()
        for ((room, at) in mutes()) if (room != code) saved.put(room, at)
        if (until != null) saved.put(code, until)
        prefs.edit().putString(KEY_MUTES, saved.toString()).apply()
    }

    /** Shows [notice] unless the person did not ask for it, or the room is quiet. */
    fun show(notice: ChatNotice) {
        if (!enabled || !granted() || notice.room in mutes()) return
        val language = SapocheApp.language.value
        val id = notice.room.hashCode()
        // A notification the person swiped away starts the count again
        val live = manager.activeNotifications.any { it.id == id }
        val said = lines.getOrPut(notice.room) { ArrayDeque() }.also { if (!live) it.clear() }
        val title = notice.title(language)
        val body = notice.body(language, preview)
        said.addLast(if (body.isEmpty()) title else if (notice.kind == ChatNotice.Kind.CHAT) "${notice.name}: $body" else "$title: $body")
        while (said.size > MAX_LINES) said.removeFirst()
        val count = if (live) (manager.activeNotifications.first { it.id == id }.notification.extras.getInt(EXTRA_COUNT) + 1) else 1

        val open = PendingIntent.getActivity(
            context,
            id,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_OPEN_CHAT, notice.room),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(context)
        builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setOnlyAlertOnce(true)
            .addExtras(android.os.Bundle().apply { putInt(EXTRA_COUNT, count) })
        if (count == 1) {
            builder.setContentTitle(title).setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
        } else {
            builder
                .setContentTitle(ChatNotices.many(count, language))
                .setContentText(said.last())
                .setStyle(Notification.InboxStyle().also { style -> said.forEach(style::addLine) })
        }
        manager.notify(id, builder.build())
    }

    /** The person is looking at the app: what was said is on its screen, and the notifications go. */
    fun clear() {
        for (room in lines.keys) manager.cancel(room.hashCode())
        lines.clear()
    }

    companion object {
        const val EXTRA_OPEN_CHAT = "app.sapoche.OPEN_CHAT"
        private const val CHANNEL = "chat"
        private const val EXTRA_COUNT = "app.sapoche.COUNT"
        private const val MAX_LINES = 5
        private const val KEY_ENABLED = "notices_enabled"
        private const val KEY_PREVIEW = "notices_preview"
        private const val KEY_MUTES = "notices_mutes"
        private const val KEY_REFUSED = "notices_refused"
    }
}
