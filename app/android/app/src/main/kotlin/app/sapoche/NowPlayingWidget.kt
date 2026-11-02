package app.sapoche

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaButtonReceiver
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** A song of what is to come, for the large widget; [by] is the id of the member who added it, in a room. */
data class WidgetRow(val id: String, val title: String, val artist: String, val by: String? = null)

/** What the widgets show: the song, whether it plays and, in a room, where. Kept so a widget can be drawn while the app is not running. */
data class WidgetState(
    val title: String = "",
    val artist: String = "",
    val playing: Boolean = false,
    /** `Room name · 3` while joined to a room, else null. */
    val room: String? = null,
    /** The next songs (at most [Widgets.NEXT_ROWS]), which the large widget lists. */
    val next: List<WidgetRow> = emptyList(),
    /** Ids of up to three of the people listening, in a room: whose faces the room line of the widgets shows. */
    val crew: List<String> = emptyList(),
    /** The room's code while joined to one, so a widget can open it. */
    val roomCode: String? = null,
) {
    fun toJson(): String = JSONObject()
        .put("title", title).put("artist", artist).put("playing", playing).put("room", room ?: JSONObject.NULL)
        .put("roomCode", roomCode ?: JSONObject.NULL)
        .put("crew", JSONArray(crew))
        .put(
            "next",
            JSONArray(next.map { JSONObject().put("id", it.id).put("title", it.title).put("artist", it.artist).put("by", it.by ?: JSONObject.NULL) }),
        )
        .toString()

    companion object {
        fun fromJson(text: String?): WidgetState = runCatching {
            val json = JSONObject(text ?: return WidgetState())
            // optString turns a JSON null into the text "null"
            fun nullable(key: String) = if (json.isNull(key)) null else json.getString(key)
            val rows = json.optJSONArray("next")
            val names = json.optJSONArray("crew")
            WidgetState(
                json.optString("title"),
                json.optString("artist"),
                json.optBoolean("playing"),
                nullable("room"),
                List(rows?.length() ?: 0) {
                    val row = rows!!.getJSONObject(it)
                    WidgetRow(row.getString("id"), row.optString("title"), row.optString("artist"), if (row.isNull("by")) null else row.getString("by"))
                },
                List(names?.length() ?: 0) { names!!.getString(it) },
                nullable("roomCode"),
            )
        }.getOrDefault(WidgetState())
    }
}

/** The three sizes of the widget that shows what plays; each is a widget of its own in the launcher's list. */
enum class NowPlayingSize(val layout: Int, val defaultWidthDp: Int, val defaultHeightDp: Int) {
    SMALL(R.layout.widget_np_small, 150, 150),
    MEDIUM(R.layout.widget_np_medium, 320, 130),
    LARGE(R.layout.widget_np_large, 320, 320),
}

/**
 * The widgets of the home screen that show what plays, with play, pause and skip. Their buttons are media buttons sent to the
 * same receiver a headset uses, so in a room they act on the room, and a guest who may not skip gets no skip.
 */
open class NowPlayingProvider(private val size: NowPlayingSize) : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        Widgets.render(context, manager, size, ids)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        Widgets.render(context, manager, size, intArrayOf(id))
    }
}

/** 4×2: the cover, the song, the buttons and the time. The widget of the first versions, so the ones already placed are this. */
class NowPlayingWidget : NowPlayingProvider(NowPlayingSize.MEDIUM)

/** 2×2: the cover filling the square, the song over it, one button. */
class NowPlayingSmallWidget : NowPlayingProvider(NowPlayingSize.SMALL)

/** 4×4: the medium widget with the next songs under it. */
class NowPlayingLargeWidget : NowPlayingProvider(NowPlayingSize.LARGE)

@UnstableApi
object Widgets {
    private const val PREFS = "sapoche"
    private const val KEY_STATE = "widget_state"
    const val COVER = "widget_cover.png"
    const val BLUR = "widget_blur.png"
    const val FACES = "widget_faces.png"
    fun nextCover(row: Int) = "widget_next$row.png"
    fun adderFile(row: Int) = "widget_by$row.png"

    const val NEXT_ROWS = 3

    private val PROVIDERS = listOf(
        NowPlayingWidget::class.java to NowPlayingSize.MEDIUM,
        NowPlayingSmallWidget::class.java to NowPlayingSize.SMALL,
        NowPlayingLargeWidget::class.java to NowPlayingSize.LARGE,
    )

    private val ROWS = listOf(
        intArrayOf(R.id.widget_row1, R.id.widget_row1_cover, R.id.widget_row1_title, R.id.widget_row1_artist, R.id.widget_row1_by),
        intArrayOf(R.id.widget_row2, R.id.widget_row2_cover, R.id.widget_row2_title, R.id.widget_row2_artist, R.id.widget_row2_by),
        intArrayOf(R.id.widget_row3, R.id.widget_row3_cover, R.id.widget_row3_title, R.id.widget_row3_artist, R.id.widget_row3_by),
    )

    private fun ids(context: Context, provider: Class<*>): IntArray =
        AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, provider))

    /** Whether a widget that follows the song and the room is on a home screen. */
    fun hasWidgets(context: Context): Boolean =
        PROVIDERS.any { ids(context, it.first).isNotEmpty() } || RoomsWidgets.hasWidgets(context)

    /**
     * Sets the size of a text in dp, not sp: a widget has a fixed room and a phone set to large letters would push the words
     * out of it (cut at the edge); the person's size of letters is for the app's own pages.
     */
    fun fixedSize(views: RemoteViews, id: Int, dp: Float) = views.setTextViewTextSize(id, android.util.TypedValue.COMPLEX_UNIT_DIP, dp)

    /** Words in the language of the app, which is not always the one of the system. */
    fun text(vi: String, en: String) = if (SapocheApp.language.value == "vi") vi else en

    /** What was last drawn. */
    fun state(context: Context): WidgetState =
        WidgetState.fromJson(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_STATE, null))

    fun picture(context: Context, name: String): Bitmap? = File(context.filesDir, name).takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path) }

    /** Draws what is shown now on every widget; the [pictures] (by file name) are kept for the next time. */
    fun update(context: Context, state: WidgetState, pictures: Map<String, Bitmap> = emptyMap()) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_STATE, state.toJson()).apply()
        for ((name, bitmap) in pictures) File(context.filesDir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 90, it) }
        val manager = AppWidgetManager.getInstance(context)
        for ((provider, size) in PROVIDERS) {
            val ids = ids(context, provider)
            if (ids.isNotEmpty()) render(context, manager, size, ids)
        }
        RoomsWidgets.redraw(context)
    }

    /** The cover as the widget shows it: square, small, with rounded corners. */
    fun rounded(source: Bitmap, sizePx: Int = 360, radiusPx: Float = 40f): Bitmap {
        val side = minOf(source.width, source.height)
        val square = Bitmap.createBitmap(source, (source.width - side) / 2, (source.height - side) / 2, side, side)
        val out = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        canvas.drawRoundRect(RectF(0f, 0f, sizePx.toFloat(), sizePx.toFloat()), radiusPx, radiusPx, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(Bitmap.createScaledBitmap(square, sizePx, sizePx, true), 0f, 0f, paint)
        return out
    }

    private val FACE_COLORS = intArrayOf(0xFFD81B60.toInt(), 0xFF5E35B1.toInt(), 0xFF00897B.toInt(), 0xFFEF6C00.toInt(), 0xFF1E88E5.toInt(), 0xFF6D4C41.toInt())

    /** A person as a round picture: their own, or their initial on a colour that is theirs. */
    fun face(key: String, name: String, picture: Bitmap?, sizePx: Int = 72): Bitmap {
        val out = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        if (picture != null) {
            val side = minOf(picture.width, picture.height)
            val square = Bitmap.createBitmap(picture, (picture.width - side) / 2, (picture.height - side) / 2, side, side)
            canvas.drawCircle(sizePx / 2f, sizePx / 2f, sizePx / 2f, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            canvas.drawBitmap(Bitmap.createScaledBitmap(square, sizePx, sizePx, true), 0f, 0f, paint)
        } else {
            paint.color = FACE_COLORS[Math.floorMod(key.hashCode(), FACE_COLORS.size)]
            canvas.drawCircle(sizePx / 2f, sizePx / 2f, sizePx / 2f, paint)
            paint.color = Color.WHITE
            paint.textAlign = Paint.Align.CENTER
            paint.textSize = sizePx * 0.5f
            paint.isFakeBoldText = true
            val initial = name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
            canvas.drawText(initial, sizePx / 2f, sizePx / 2f - (paint.descent() + paint.ascent()) / 2f, paint)
        }
        return out
    }

    /** Several faces side by side, each overlapping the one before; [ring] is the colour round each of them. */
    fun faces(list: List<Bitmap>, ring: Int, sizePx: Int = 72): Bitmap {
        if (list.isEmpty()) return Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        val step = sizePx * 3 / 4
        val out = Bitmap.createBitmap(sizePx + step * (list.size - 1), sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        list.forEachIndexed { i, face ->
            val x = (step * i).toFloat()
            paint.color = ring
            canvas.drawCircle(x + sizePx / 2f, sizePx / 2f, sizePx / 2f, paint)
            canvas.drawBitmap(Bitmap.createScaledBitmap(face, sizePx - 6, sizePx - 6, true), x + 3, 3f, null)
        }
        return out
    }

    /**
     * The size of a cell in dp. In portrait it is as wide as the least width the launcher reports and as high as the greatest
     * height, and the other way round in landscape (the documentation of `AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH`); the
     * least of both is only what the cell could be shrunk to.
     */
    fun cellSize(context: Context, options: Bundle, defaultWidthDp: Int, defaultHeightDp: Int): Pair<Int, Int> {
        val portrait = context.resources.configuration.orientation != android.content.res.Configuration.ORIENTATION_LANDSCAPE
        fun dp(key: String, fallback: Int) = options.getInt(key, 0).takeIf { it > 0 } ?: fallback
        val width = if (portrait) dp(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, defaultWidthDp) else dp(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, defaultWidthDp)
        val height = if (portrait) dp(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, defaultHeightDp) else dp(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, defaultHeightDp)
        return width to height
    }

    fun render(context: Context, manager: AppWidgetManager, size: NowPlayingSize, ids: IntArray) {
        val state = state(context)
        for (id in ids) {
            val (width, height) = cellSize(context, manager.getAppWidgetOptions(id), size.defaultWidthDp, size.defaultHeightDp)
            manager.updateAppWidget(id, views(context, state, size, width, height))
        }
    }

    /** One widget of [widthDp] by [heightDp] showing [state]. */
    fun views(context: Context, state: WidgetState, size: NowPlayingSize, widthDp: Int, heightDp: Int): RemoteViews {
        val cover = picture(context, COVER)
        val tiny = picture(context, BLUR)
        val accent = WidgetArt.accent(tiny)
        val faces = picture(context, FACES)
        val idle = state.title.isEmpty()
        val views = RemoteViews(context.packageName, size.layout)
        val art = if (size == NowPlayingSize.SMALL) WidgetArt.cover(widthDp, heightDp, cover, accent) else WidgetArt.background(widthDp, heightDp, tiny, accent)
        views.setImageViewBitmap(R.id.widget_bg, art)
        val small = size == NowPlayingSize.SMALL
        fixedSize(views, R.id.widget_title, if (small) 15f else 17f)
        fixedSize(views, R.id.widget_artist, if (small) 12f else 13f)
        views.setTextViewText(R.id.widget_title, if (idle) "Sapoche" else state.title)
        views.setTextViewText(R.id.widget_artist, if (idle) text("Chưa phát gì", "Nothing playing") else state.artist)
        views.setImageViewResource(R.id.widget_play, if (state.playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play)
        views.setOnClickPendingIntent(R.id.widget_play, key(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        views.setOnClickPendingIntent(R.id.widget_root, openApp(context))
        if (size == NowPlayingSize.SMALL) return views

        if (cover != null) views.setImageViewBitmap(R.id.widget_cover, cover) else views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
        // Straight to the app, like a touch on a song of the queue: through the media key receiver they did nothing
        views.setOnClickPendingIntent(R.id.widget_prev, WidgetActions.previous(context))
        views.setOnClickPendingIntent(R.id.widget_next, WidgetActions.next(context))
        fixedSize(views, R.id.widget_room, 11f)
        views.setTextViewText(R.id.widget_room, state.room.orEmpty())
        views.setViewVisibility(R.id.widget_room_line, if (state.room != null) View.VISIBLE else View.GONE)
        val showFaces = state.room != null && faces != null && state.crew.isNotEmpty()
        views.setViewVisibility(R.id.widget_faces, if (showFaces) View.VISIBLE else View.GONE)
        if (showFaces) views.setImageViewBitmap(R.id.widget_faces, faces)
        if (size == NowPlayingSize.MEDIUM) scaleMedium(context, views, widthDp, heightDp)
        if (size == NowPlayingSize.LARGE) renderNext(context, views, state)
        return views
    }

    /** What the medium layout holds at 1: a cell 130 dp high and 320 wide. */
    private const val MEDIUM_BASE_HEIGHT = 105f
    private const val MEDIUM_BASE_WIDTH = 240f

    /** How much bigger than the layout's own sizes the medium widget is drawn in a cell of [widthDp] by [heightDp]; never smaller. */
    fun mediumScale(widthDp: Int, heightDp: Int): Float =
        minOf(heightDp * 0.66f / MEDIUM_BASE_HEIGHT, widthDp / MEDIUM_BASE_WIDTH, 1.7f).coerceAtLeast(1f)

    /**
     * A cell taller than the layout was made for would leave its content in a band with empty space above and below, so the
     * cover, the words and the buttons grow with the cell. A RemoteViews can only be given other sizes from Android 12; before
     * that the layout stays as it is, in the middle.
     */
    private fun scaleMedium(context: Context, views: RemoteViews, widthDp: Int, heightDp: Int) {
        val scale = mediumScale(widthDp, heightDp)
        EventLog.d("widget", "medium widget in ${widthDp}x${heightDp} dp, drawn at x$scale")
        if (scale <= 1f || android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S) return
        val dp = android.util.TypedValue.COMPLEX_UNIT_DIP
        fun square(id: Int, sideDp: Float) {
            views.setViewLayoutWidth(id, sideDp * scale, dp)
            views.setViewLayoutHeight(id, sideDp * scale, dp)
        }
        square(R.id.widget_cover, 92f)
        square(R.id.widget_play, 40f)
        square(R.id.widget_prev, 32f)
        square(R.id.widget_next, 32f)
        val density = context.resources.displayMetrics.density
        fun pad(id: Int, paddingDp: Float) = (paddingDp * scale * density).toInt().let { views.setViewPadding(id, it, it, it, it) }
        pad(R.id.widget_content, 10f)
        pad(R.id.widget_play, 8f)
        pad(R.id.widget_prev, 6f)
        pad(R.id.widget_next, 6f)
        views.setViewLayoutMargin(R.id.widget_text_column, RemoteViews.MARGIN_START, 12f * scale, dp)
        views.setViewLayoutMargin(R.id.widget_controls, RemoteViews.MARGIN_TOP, 6f * scale, dp)
        // The words grow slower than the cover and the buttons: the column they are in does not grow with the cell, and a long title
        // would be cut
        val text = 1f + (scale - 1f) * 0.4f
        fixedSize(views, R.id.widget_title, 17f * text)
        fixedSize(views, R.id.widget_artist, 13f * text)
        fixedSize(views, R.id.widget_room, 11f * text)
    }

    private fun renderNext(context: Context, views: RemoteViews, state: WidgetState) {
        fixedSize(views, R.id.widget_next_header, 11f)
        views.setTextViewText(R.id.widget_next_header, text("Tiếp theo", "Up next"))
        views.setViewVisibility(R.id.widget_next_list, if (state.next.isEmpty()) View.GONE else View.VISIBLE)
        ROWS.forEachIndexed { i, (row, cover, title, artist, by) ->
            val item = state.next.getOrNull(i)
            views.setViewVisibility(row, if (item == null) View.GONE else View.VISIBLE)
            if (item == null) return@forEachIndexed
            fixedSize(views, title, 14f)
            fixedSize(views, artist, 12f)
            views.setTextViewText(title, item.title)
            views.setTextViewText(artist, item.artist)
            val thumb = picture(context, nextCover(i))
            if (thumb != null) views.setImageViewBitmap(cover, thumb) else views.setImageViewResource(cover, R.mipmap.ic_launcher)
            val who = if (item.by != null) picture(context, adderFile(i)) else null
            views.setViewVisibility(by, if (who != null) View.VISIBLE else View.GONE)
            if (who != null) views.setImageViewBitmap(by, who)
            views.setOnClickPendingIntent(row, WidgetActions.jump(context, i, item.id))
        }
    }

    fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** A press of a media key, as a headset sends it: the receiver starts the service if it is not running and the session decides. */
    private fun key(context: Context, code: Int): PendingIntent = PendingIntent.getBroadcast(
        context,
        code,
        Intent(Intent.ACTION_MEDIA_BUTTON)
            .setComponent(ComponentName(context, MediaButtonReceiver::class.java))
            .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, code)),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}
