package app.sapoche

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.view.LayoutInflater
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
 * checked for what they say. A home screen is not needed: the views are the ones a launcher would show.
 */
@UnstableApi
class WidgetLayoutTest {

    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val folder = File(context.getExternalFilesDir(null), "widgets").also { it.mkdirs() }

    private fun density() = context.resources.displayMetrics.density

    /** [view] laid out at [widthDp] by [heightDp], saved as [name].png. */
    private fun shoot(name: String, view: View, widthDp: Int, heightDp: Int) {
        val w = (widthDp * density()).toInt()
        val h = (heightDp * density()).toInt()
        view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, w, h)
        val picture = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        picture.eraseColor(Color.parseColor("#FF3A4A5A"))
        view.draw(Canvas(picture))
        File(folder, "$name.png").outputStream().use { picture.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun swatch(color: Int, size: Int = 160) = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also { it.eraseColor(color) }

    private fun keep(name: String, bitmap: Bitmap) = File(context.filesDir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }

    private fun nowPlaying(state: WidgetState, widthDp: Int, heightDp: Int, name: String): View {
        keep(Widgets.COVER, Widgets.rounded(swatch(Color.parseColor("#E91E63"), 400)))
        keep(Widgets.FACES, Widgets.faces(listOf("Lan", "Minh", "Hà").map { Widgets.face(it, it, null) }, Color.WHITE))
        state.next.forEachIndexed { i, row ->
            keep(Widgets.nextCover(i), Widgets.rounded(swatch(Color.parseColor(listOf("#43A047", "#1E88E5", "#FB8C00")[i])), 96, 12f))
            if (row.by != null) keep(Widgets.adderFile(i), Widgets.face(row.by, row.by, null))
        }
        val root = FrameLayout(context)
        val inflated = Widgets.views(context, state, widthDp, heightDp).apply(context, root)
        root.addView(inflated, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        shoot(name, root, widthDp, heightDp)
        return root
    }

    private val room = WidgetState(
        "MAKING MY WAY", "Sơn Tùng M-TP", true, "Cuối tuần · 4",
        listOf(WidgetRow("a", "Cheri Cheri Lady", "Maléna", "Lan"), WidgetRow("b", "STAY", "The Kid LAROI & Justin Bieber", "Minh"), WidgetRow("c", "Có Chắc Yêu Là Đây", "Sơn Tùng M-TP", "Hà")),
        listOf("Lan", "Minh", "Hà"), "ABC123",
    )

    private fun texts(view: View): List<String> =
        if (view is TextView) listOf(view.text.toString()) else if (view is ViewGroup) (0 until view.childCount).flatMap { texts(view.getChildAt(it)) } else emptyList()

    @Test
    fun theLargeWidgetListsWhatComesNext() {
        val said = texts(nowPlaying(room, 340, 330, "now_large"))
        assertTrue(said.toString(), "Cheri Cheri Lady" in said && "STAY" in said && "Có Chắc Yêu Là Đây" in said)
        assertTrue(said.toString(), "MAKING MY WAY" in said)
    }

    @Test
    fun aLargeWidgetWithNothingNextHidesTheList() {
        val root = nowPlaying(room.copy(next = emptyList()), 340, 330, "now_large_empty")
        assertTrue(texts(root).none { it == "Cheri Cheri Lady" })
    }

    @Test
    fun theMediumWidgetStaysMedium() {
        val said = texts(nowPlaying(room, 340, 130, "now_medium"))
        assertTrue(said.toString(), "Cuối tuần · 4" in said)
        assertTrue(said.toString(), "STAY" !in said)
    }

    @Test
    fun theSmallWidgetHasTheTitleAndNoControls() {
        val said = texts(nowPlaying(room.copy(room = null, crew = emptyList(), roomCode = null), 148, 148, "now_small"))
        assertEquals(listOf("MAKING MY WAY", "Sơn Tùng M-TP"), said)
    }

    @Test
    fun nothingPlayingSaysSo() {
        val said = texts(nowPlaying(WidgetState(), 340, 130, "now_idle"))
        assertTrue(said.toString(), "Sapoche" in said)
    }

    @Test
    fun theStateSurvivesBeingKept() {
        assertEquals(room, WidgetState.fromJson(room.toJson()))
        assertEquals(WidgetState(), WidgetState.fromJson(null))
        assertEquals(WidgetState(), WidgetState.fromJson("not json"))
    }

    @Test
    fun theQuickAndRoomsLayoutsFit() {
        val inflater = LayoutInflater.from(context)
        val quick = inflater.inflate(R.layout.widget_quick, null)
        listOf(R.id.widget_tile1_label to "Bài thích", R.id.widget_tile2_label to "Mix gợi ý", R.id.widget_tile3_label to "Tải về", R.id.widget_tile4_label to "Cuối tuần")
            .forEach { (id, label) -> quick.findViewById<TextView>(id).text = label }
        shoot("quick", quick, 340, 74)

        val rooms = inflater.inflate(R.layout.widget_rooms, null)
        rooms.findViewById<android.widget.ImageView>(R.id.widget_rooms_faces)
            .setImageBitmap(Widgets.faces(listOf("Lan", "Minh").map { Widgets.face(it, it, null) }, Color.parseColor("#FF1F1B1D")))
        rooms.findViewById<TextView>(R.id.widget_rooms_title).text = "Lan, Minh đang nghe"
        rooms.findViewById<TextView>(R.id.widget_rooms_sub).text = "Cuối tuần · STAY"
        rooms.findViewById<TextView>(R.id.widget_rooms_button).text = "Vào nghe"
        shoot("rooms", rooms, 340, 76)
        assertTrue(File(folder, "rooms.png").length() > 0)
    }
}
