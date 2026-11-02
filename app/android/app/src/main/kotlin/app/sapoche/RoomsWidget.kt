package app.sapoche

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import androidx.media3.common.util.UnstableApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import org.json.JSONArray
import org.json.JSONObject

/** The room worth showing when this device is in none: where friends are listening now, else the one it was in last. */
private data class Friends(val code: String, val room: String, val who: List<String>, val song: String?) {
    fun toJson(): String = JSONObject().put("code", code).put("room", room).put("who", JSONArray(who)).put("song", song ?: JSONObject.NULL).toString()

    companion object {
        fun fromJson(text: String?): Friends? = runCatching {
            val json = JSONObject(text ?: return null)
            val names = json.getJSONArray("who")
            Friends(json.getString("code"), json.getString("room"), List(names.length()) { names.getString(it) }, if (json.isNull("song")) null else json.getString("song"))
        }.getOrNull()
    }
}

/**
 * The widget that says who listens: in a room, the room and its song; outside one, the friends in the rooms this device
 * has been in, with a way to join. It asks the server only when the system updates it (an hour at most), never in the
 * background by itself.
 */
@UnstableApi
class RoomsWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        draw(context)
        refresh(context)
    }

    companion object {
        private const val PREFS = "sapoche"
        private const val KEY_FRIENDS = "widget_friends"
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private val http by lazy { OkHttpClient() }

        private fun ids(context: Context): IntArray =
            AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, RoomsWidget::class.java))

        fun hasWidgets(context: Context): Boolean = ids(context).isNotEmpty()

        /** Asks the server about the recent rooms and draws the answer. */
        fun refresh(context: Context) {
            if (ids(context).isEmpty()) return
            val app = context.applicationContext
            scope.launch {
                val found = runCatching { friends(app) }.getOrNull()
                val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                // A server that could not be reached leaves what was known
                if (found != null) prefs.edit().putString(KEY_FRIENDS, found.toJson()).apply() else if (CarRooms(app, http).read().isEmpty()) prefs.edit().remove(KEY_FRIENDS).apply()
                draw(app)
            }
        }

        /** Draws what is known now, which changes when the room joined or left does. */
        fun redraw(context: Context) {
            if (ids(context).isNotEmpty()) draw(context)
        }

        private suspend fun friends(context: Context): Friends? = coroutineScope {
            CarRooms(context, http).read().take(5).map { room ->
                async { runCatching { RoomInfo.fetch(http, room.code) }.getOrNull()?.takeIf { it["exists"] == true }?.let { room to it } }
            }.awaitAll().filterNotNull().let { rooms ->
                val listened = rooms.firstOrNull { (_, info) -> (info["who"] as? List<*>).orEmpty().isNotEmpty() }
                (listened ?: rooms.firstOrNull())?.let { (room, info) ->
                    Friends(
                        room.code,
                        (info["name"] as? String) ?: room.name ?: room.code,
                        (info["who"] as? List<*>).orEmpty().filterIsInstance<String>(),
                        info["title"] as? String,
                    )
                }
            }
        }

        private fun draw(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = ids(context)
            if (ids.isEmpty()) return
            val state = Widgets.state(context)
            val friends = Friends.fromJson(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_FRIENDS, null))
            val views = RemoteViews(context.packageName, R.layout.widget_rooms)
            val ring = context.getColor(R.color.widget_bg)
            when {
                state.roomCode != null -> {
                    views.setTextViewText(R.id.widget_rooms_title, state.room.orEmpty())
                    views.setTextViewText(R.id.widget_rooms_sub, state.title.ifEmpty { Widgets.text("Chưa phát gì", "Nothing playing") })
                    Widgets.picture(context, Widgets.FACES)?.let { views.setImageViewBitmap(R.id.widget_rooms_faces, it) }
                    views.setTextViewText(R.id.widget_rooms_button, Widgets.text("Mở", "Open"))
                    views.setOnClickPendingIntent(R.id.widget_root, Widgets.openApp(context))
                }
                friends != null -> {
                    val listening = friends.who.isNotEmpty()
                    val title = if (listening) {
                        Widgets.text("${friends.who.take(2).joinToString(", ")} đang nghe", "${friends.who.take(2).joinToString(", ")} listening")
                    } else {
                        Widgets.text("Chưa ai nghe", "Nobody is listening")
                    }
                    views.setTextViewText(R.id.widget_rooms_title, title)
                    views.setTextViewText(
                        R.id.widget_rooms_sub,
                        if (listening) listOfNotNull(friends.room, friends.song).joinToString(" · ") else Widgets.text("Phòng gần nhất: ${friends.room}", "Last room: ${friends.room}"),
                    )
                    val names = friends.who.ifEmpty { listOf(friends.room) }
                    views.setImageViewBitmap(R.id.widget_rooms_faces, Widgets.faces(names.take(3).map { Widgets.face(it, it, null) }, ring))
                    views.setTextViewText(R.id.widget_rooms_button, if (listening) Widgets.text("Vào nghe", "Join") else Widgets.text("Mở phòng", "Open"))
                    val join = PendingIntent.getActivity(
                        context,
                        1,
                        Intent(Intent.ACTION_VIEW, Uri.parse("sapoche://join/${friends.code}")).setClass(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    )
                    views.setOnClickPendingIntent(R.id.widget_root, join)
                }
                else -> {
                    views.setTextViewText(R.id.widget_rooms_title, Widgets.text("Chưa có phòng", "No rooms yet"))
                    views.setTextViewText(R.id.widget_rooms_sub, Widgets.text("Tạo hoặc vào một phòng", "Start or join a room"))
                    views.setImageViewResource(R.id.widget_rooms_faces, R.mipmap.ic_launcher)
                    views.setTextViewText(R.id.widget_rooms_button, Widgets.text("Mở", "Open"))
                    views.setOnClickPendingIntent(R.id.widget_root, Widgets.openApp(context))
                }
            }
            for (id in ids) manager.updateAppWidget(id, views)
        }
    }
}
