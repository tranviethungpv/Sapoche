package app.sapoche

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.view.View
import android.widget.RemoteViews
import androidx.media3.common.util.UnstableApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** The two shapes of the widget that plays a list with one touch; each is a widget of its own in the launcher's list. */
enum class QuickSize(val layout: Int, val defaultWidthDp: Int, val defaultHeightDp: Int) {
    WIDE(R.layout.widget_quick_wide, 320, 80),
    GRID(R.layout.widget_quick_grid, 150, 150),
}

/** Four tiles that play a list with one touch, without opening the app: liked songs, a mix for you, downloads and the latest playlist. */
@UnstableApi
open class QuickProvider(private val size: QuickSize) : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        val app = context.applicationContext
        scope.launch {
            try {
                // The playlist touched last; the library is the app's own, in this process
                val playlist = runCatching { SapocheApp.library.playlists().firstOrNull() }.getOrNull()
                for (id in ids) {
                    val options = manager.getAppWidgetOptions(id)
                    val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0).takeIf { it > 0 } ?: size.defaultWidthDp
                    val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0).takeIf { it > 0 } ?: size.defaultHeightDp
                    manager.updateAppWidget(id, views(app, size, width, height, playlist))
                }
            } finally {
                pending.finish()
            }
        }
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: android.os.Bundle) {
        onUpdate(context, manager, intArrayOf(id))
    }

    companion object {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        /** One widget of [widthDp] by [heightDp]; the fourth tile is the latest [playlist], and is left out when there is none. */
        fun views(context: Context, size: QuickSize, widthDp: Int, heightDp: Int, playlist: LibraryStore.Playlist?): RemoteViews {
            val views = RemoteViews(context.packageName, size.layout)
            val tiny = Widgets.picture(context, Widgets.BLUR)
            views.setImageViewBitmap(R.id.widget_bg, WidgetArt.background(widthDp, heightDp, tiny, WidgetArt.accent(tiny)))
            val tiles = listOf(
                Triple(R.id.widget_tile1, R.id.widget_tile1_label, Widgets.text("Bài thích", "Liked") to WidgetActions.quick(context, WidgetActions.LIKED)),
                Triple(R.id.widget_tile2, R.id.widget_tile2_label, Widgets.text("Mix gợi ý", "Mix") to WidgetActions.quick(context, WidgetActions.MIX)),
                Triple(R.id.widget_tile3, R.id.widget_tile3_label, Widgets.text("Tải về", "Downloads") to WidgetActions.quick(context, WidgetActions.DOWNLOADS)),
            )
            for ((tile, label, shown) in tiles) {
                Widgets.fixedSize(views, label, 10f)
                views.setTextViewText(label, shown.first)
                views.setOnClickPendingIntent(tile, shown.second)
            }
            // With no playlist yet the fourth tile has nothing to play
            views.setViewVisibility(R.id.widget_tile4, if (playlist == null) View.INVISIBLE else View.VISIBLE)
            if (playlist != null) {
                Widgets.fixedSize(views, R.id.widget_tile4_label, 10f)
                views.setTextViewText(R.id.widget_tile4_label, playlist.name)
                views.setOnClickPendingIntent(R.id.widget_tile4, WidgetActions.quick(context, WidgetActions.PLAYLIST, playlist.id))
            }
            return views
        }
    }
}

/** 4×1. */
@UnstableApi
class QuickWidget : QuickProvider(QuickSize.WIDE)

/** 2×2: the four tiles as a grid. */
@UnstableApi
class QuickGridWidget : QuickProvider(QuickSize.GRID)
