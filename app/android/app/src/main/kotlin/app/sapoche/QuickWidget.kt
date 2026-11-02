package app.sapoche

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews
import androidx.media3.common.util.UnstableApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Four tiles that play a list with one touch, without opening the app: liked songs, a mix for you, downloads and the latest playlist. */
@UnstableApi
class QuickWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        val app = context.applicationContext
        scope.launch {
            try {
                // The playlist touched last; the library is the app's own, in this process
                val playlist = runCatching { SapocheApp.library.playlists().firstOrNull() }.getOrNull()
                draw(app, manager, ids, playlist)
            } finally {
                pending.finish()
            }
        }
    }

    private fun draw(context: Context, manager: AppWidgetManager, ids: IntArray, playlist: LibraryStore.Playlist?) {
        val views = RemoteViews(context.packageName, R.layout.widget_quick)
        val tiles = listOf(
            Triple(R.id.widget_tile1, R.id.widget_tile1_label, Widgets.text("Bài thích", "Liked") to WidgetActions.quick(context, WidgetActions.LIKED)),
            Triple(R.id.widget_tile2, R.id.widget_tile2_label, Widgets.text("Mix gợi ý", "Mix") to WidgetActions.quick(context, WidgetActions.MIX)),
            Triple(R.id.widget_tile3, R.id.widget_tile3_label, Widgets.text("Tải về", "Downloads") to WidgetActions.quick(context, WidgetActions.DOWNLOADS)),
        )
        for ((tile, label, shown) in tiles) {
            views.setTextViewText(label, shown.first)
            views.setOnClickPendingIntent(tile, shown.second)
        }
        // With no playlist yet the fourth tile has nothing to play
        views.setViewVisibility(R.id.widget_tile4, if (playlist == null) View.INVISIBLE else View.VISIBLE)
        if (playlist != null) {
            views.setTextViewText(R.id.widget_tile4_label, playlist.name)
            views.setOnClickPendingIntent(R.id.widget_tile4, WidgetActions.quick(context, WidgetActions.PLAYLIST, playlist.id))
        }
        for (id in ids) manager.updateAppWidget(id, views)
    }

    companion object {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}
