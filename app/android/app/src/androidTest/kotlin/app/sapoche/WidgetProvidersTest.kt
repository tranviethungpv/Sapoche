package app.sapoche

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.media3.common.util.UnstableApi
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * The widgets as a launcher holds them: bound to a host that is given what the providers send. Needs `appwidget grantbind`,
 * which the shell is allowed to run, so it is done here for this app.
 */
@UnstableApi
class WidgetProvidersTest {

    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val manager = AppWidgetManager.getInstance(context)
    private val host = AppWidgetHost(context, HOST_ID)
    private val bound = mutableListOf<Int>()

    @Before
    fun allowBinding() {
        instrumentation.uiAutomation.executeShellCommand("appwidget grantbind --package ${context.packageName} --user 0").close()
        Thread.sleep(500)
        instrumentation.runOnMainSync { host.startListening() }
    }

    @After
    fun release() {
        bound.forEach { host.deleteAppWidgetId(it) }
        instrumentation.runOnMainSync { host.stopListening() }
    }

    private fun place(provider: Class<*>): AppWidgetHostView {
        val id = host.allocateAppWidgetId()
        bound += id
        assertTrue("could not bind ${provider.simpleName}", manager.bindAppWidgetIdIfAllowed(id, ComponentName(context, provider)))
        lateinit var view: AppWidgetHostView
        instrumentation.runOnMainSync { view = host.createView(context, id, manager.getAppWidgetInfo(id)) }
        return view
    }

    private fun texts(view: View): List<String> =
        if (view is TextView) listOf(view.text.toString()) else if (view is ViewGroup) (0 until view.childCount).flatMap { texts(view.getChildAt(it)) } else emptyList()

    /** What the widget says once [done] holds, as the system has delivered it; fails after a while. */
    private fun waitFor(view: AppWidgetHostView, what: String, done: (List<String>) -> Boolean): List<String> {
        repeat(40) {
            var said = emptyList<String>()
            instrumentation.runOnMainSync { said = texts(view) }
            if (done(said)) return said
            Thread.sleep(250)
        }
        throw AssertionError("$what: ${texts(view)}")
    }

    private fun shoot(name: String, view: View, widthDp: Int, heightDp: Int) {
        instrumentation.runOnMainSync {
            val w = (widthDp * context.resources.displayMetrics.density).toInt()
            val h = (heightDp * context.resources.displayMetrics.density).toInt()
            view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, w, h)
            val picture = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            picture.eraseColor(0xFF3A4A5A.toInt())
            view.draw(Canvas(picture))
            val folder = File(context.getExternalFilesDir(null), "widgets").also { it.mkdirs() }
            File(folder, "$name.png").outputStream().use { picture.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    @Test
    fun theQuickWidgetOffersItsListsAndTheLatestPlaylist() {
        runBlocking { SapocheApp.library.createPlaylist("Road trip", listOf(TrackRef("abc", "T", "A", null, 1000))) }
        val view = place(QuickWidget::class.java)
        val said = waitFor(view, "tiles") { "Road trip" in it }
        shoot("provider_quick", view, 340, 74)
        assertTrue(said.toString(), said.size >= 4)
    }

    @Test
    fun theRoomsWidgetFollowsTheRoomThisDeviceIsIn() {
        val view = place(RoomsWidget::class.java)
        waitFor(view, "no rooms") { it.isNotEmpty() && it.any { s -> s.isNotEmpty() } }
        shoot("provider_rooms_none", view, 340, 76)
        // Joined to a room: the widget says which and what plays there
        Widgets.update(context, WidgetState("STAY", "The Kid LAROI", true, "Cuối tuần · 4", roomCode = "ABC123"))
        val said = waitFor(view, "in a room") { "Cuối tuần · 4" in it }
        shoot("provider_rooms_in", view, 340, 76)
        assertTrue(said.toString(), "STAY" in said)
    }

    private companion object {
        const val HOST_ID = 4242
    }
}
