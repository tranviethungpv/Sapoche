package app.sapoche

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.media3.common.util.UnstableApi
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The widgets are drawn into pictures that the test leaves in the app's external files folder (`widgets/`), to look at, and
 * checked for what they say. A home screen is not needed: the views are the ones a launcher would show. Each is saved twice:
 * on a wallpaper (to judge it by) and on nothing (to be the picture the launcher's list of widgets shows).
 */
@UnstableApi
class WidgetLayoutTest {

    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val folder = File(context.getExternalFilesDir(null), "widgets").also { it.mkdirs() }

    private fun density() = context.resources.displayMetrics.density

    private fun draw(view: View, widthDp: Int, heightDp: Int, background: Int?): Bitmap {
        val w = (widthDp * density()).toInt()
        val h = (heightDp * density()).toInt()
        view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, w, h)
        val picture = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(picture)
        if (background != null) {
            // A wallpaper is not flat: the widget has to be told apart from something coloured
            val paint = Paint().apply { shader = LinearGradient(0f, 0f, w.toFloat(), h.toFloat(), background, Color.parseColor("#FF1C2733"), Shader.TileMode.CLAMP) }
            canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
        }
        view.draw(canvas)
        return picture
    }

    private fun save(name: String, picture: Bitmap) = File(folder, "$name.png").outputStream().use { picture.compress(Bitmap.CompressFormat.PNG, 100, it) }

    /** Puts [views] on the screen's way (inflated), saves it twice, and gives it back to be read. */
    private fun shoot(name: String, views: android.widget.RemoteViews, widthDp: Int, heightDp: Int): View {
        val root = FrameLayout(context)
        root.addView(views.apply(context, root), ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        save(name, draw(root, widthDp, heightDp, Color.parseColor("#FF7A8FA8")))
        save("preview_$name", draw(root, widthDp, heightDp, null))
        return root
    }

    private fun swatch(color: Int, size: Int = 400) = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also { c ->
        val canvas = Canvas(c)
        // Not flat, like a cover
        canvas.drawRect(0f, 0f, size.toFloat(), size.toFloat(), Paint().apply { shader = LinearGradient(0f, 0f, size.toFloat(), size.toFloat(), color, Color.parseColor("#FF101820"), Shader.TileMode.CLAMP) })
        canvas.drawCircle(size * 0.65f, size * 0.4f, size * 0.22f, Paint().apply { this.color = Color.parseColor("#FFFFD27A") })
    }

    private fun keep(name: String, bitmap: Bitmap) = File(context.filesDir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }

    private fun seed(next: List<WidgetRow>, cover: Int = Color.parseColor("#FFE91E63")) {
        val art = swatch(cover)
        keep(Widgets.COVER, Widgets.rounded(art))
        keep(Widgets.BLUR, WidgetArt.tiny(art))
        keep(Widgets.FACES, Widgets.faces(listOf("Lan", "Minh", "Hà").map { Widgets.face(it, it, null) }, Color.WHITE))
        next.forEachIndexed { i, row ->
            keep(Widgets.nextCover(i), Widgets.rounded(swatch(Color.parseColor(listOf("#FF43A047", "#FF1E88E5", "#FFFB8C00")[i]), 200), 96, 12f))
            if (row.by != null) keep(Widgets.adderFile(i), Widgets.face(row.by, row.by, null))
        }
    }

    private val room = WidgetState(
        "MAKING MY WAY", "Sơn Tùng M-TP", true, "Cuối tuần · 4",
        listOf(WidgetRow("a", "Cheri Cheri Lady", "Maléna", "Lan"), WidgetRow("b", "STAY", "The Kid LAROI & Justin Bieber", "Minh"), WidgetRow("c", "Có Chắc Yêu Là Đây", "Sơn Tùng M-TP", "Hà")),
        listOf("Lan", "Minh", "Hà"), "ABC123",
    )

    private fun texts(view: View): List<String> =
        if (view is TextView) listOf(view.text.toString()) else if (view is ViewGroup) (0 until view.childCount).flatMap { texts(view.getChildAt(it)) } else emptyList()

    private fun nowPlaying(state: WidgetState, size: NowPlayingSize, w: Int, h: Int, name: String): View {
        seed(state.next)
        return shoot(name, Widgets.views(context, state, size, w, h), w, h)
    }

    @Test
    fun theLargeWidgetListsWhatComesNext() {
        val said = texts(nowPlaying(room, NowPlayingSize.LARGE, 320, 320, "now_large"))
        assertTrue(said.toString(), "Cheri Cheri Lady" in said && "STAY" in said && "Có Chắc Yêu Là Đây" in said)
        assertTrue(said.toString(), "MAKING MY WAY" in said)
    }

    @Test
    fun aLargeWidgetWithNothingNextHidesTheList() {
        val root = nowPlaying(room.copy(next = emptyList()), NowPlayingSize.LARGE, 320, 320, "now_large_empty")
        assertTrue(texts(root).none { it == "Cheri Cheri Lady" })
    }

    @Test
    fun theMediumWidgetHasTheRoom() {
        val said = texts(nowPlaying(room, NowPlayingSize.MEDIUM, 320, 130, "now_medium"))
        assertTrue(said.toString(), "Cuối tuần · 4" in said)
        assertTrue(said.toString(), "STAY" !in said)
    }

    @Test
    fun theMediumWidgetOutsideARoomIsLightAndPaused() {
        nowPlaying(room.copy(room = null, crew = emptyList(), roomCode = null, playing = false, next = emptyList()), NowPlayingSize.MEDIUM, 320, 130, "now_medium_alone")
    }

    @Test
    fun theMediumWidgetGrowsWithATallCellAndStaysWithinAShortOne() {
        assertEquals(1f, Widgets.mediumScale(320, 130), 0f)
        assertEquals(1f, Widgets.mediumScale(320, 90), 0f)
        // A tall cell: what the layout holds is drawn bigger, but never wider than the cell has room for
        assertTrue(Widgets.mediumScale(380, 228) in 1.3f..1.7f)
        assertTrue(Widgets.mediumScale(260, 400) <= 260 / 240f)
        assertEquals(1.7f, Widgets.mediumScale(900, 900), 0f)
        val said = texts(nowPlaying(room, NowPlayingSize.MEDIUM, 380, 228, "now_medium_tall"))
        assertTrue(said.toString(), "Cuối tuần · 4" in said)
        nowPlaying(room.copy(room = null, crew = emptyList(), roomCode = null, playing = false, next = emptyList()), NowPlayingSize.MEDIUM, 380, 228, "now_medium_tall_alone")
    }

    @Test
    fun theSmallWidgetIsTheCoverWithTheSong() {
        val said = texts(nowPlaying(room, NowPlayingSize.SMALL, 150, 150, "now_small"))
        assertEquals(listOf("MAKING MY WAY", "Sơn Tùng M-TP"), said)
    }

    @Test
    fun nothingPlayingSaysSo() {
        val said = texts(nowPlaying(WidgetState(), NowPlayingSize.MEDIUM, 320, 130, "now_idle"))
        assertTrue(said.toString(), "Sapoche" in said)
    }

    @Test
    fun theStateSurvivesBeingKept() {
        assertEquals(room, WidgetState.fromJson(room.toJson()))
        assertEquals(WidgetState(), WidgetState.fromJson(null))
        assertEquals(WidgetState(), WidgetState.fromJson("not json"))
    }

    @Test
    fun theQuickWidgetsFit() {
        seed(emptyList())
        val playlist = LibraryStore.Playlist(1, "Cuối tuần", 3, emptyList(), 0)
        val wide = texts(shoot("quick_wide", QuickProvider.views(context, QuickSize.WIDE, 320, 80, playlist), 320, 80))
        assertTrue(wide.toString(), "Cuối tuần" in wide)
        shoot("quick_grid", QuickProvider.views(context, QuickSize.GRID, 150, 150, playlist), 150, 150)
    }

    @Test
    fun theRoomsWidgetsFit() {
        seed(emptyList())
        val friends = Friends("ABC123", "Cuối tuần", listOf("Lan", "Minh"), "STAY")
        val wide = texts(shoot("rooms_wide", RoomsWidgets.preview(context, WidgetState(), friends, RoomsSize.WIDE, 320, 72), 320, 72))
        assertTrue(wide.toString(), "Lan, Minh đang nghe" in wide || "Lan, Minh listening" in wide)
        shoot("rooms_small", RoomsWidgets.preview(context, WidgetState(), friends, RoomsSize.SMALL, 150, 150), 150, 150)
        shoot("rooms_in", RoomsWidgets.preview(context, room, friends, RoomsSize.WIDE, 320, 72), 320, 72)
    }
}
