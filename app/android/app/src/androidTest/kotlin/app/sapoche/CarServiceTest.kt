package app.sapoche

import android.content.ComponentName
import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaBrowser
import androidx.media3.session.SessionToken
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.util.concurrent.ListenableFuture
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.TimeUnit

/** The playback service as a car's screen meets it: a browser connects and walks the tree. */
class CarServiceTest {

    @Test
    fun aBrowserCanWalkTheTreeOfTheService() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        // Started on the main thread, which the connection needs; waited for here, off it
        var pending: ListenableFuture<MediaBrowser>? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { pending = MediaBrowser.Builder(context, token).buildAsync() }
        val connected = pending!!.get(30, TimeUnit.SECONDS)
        try {
            val root = ask { connected.getLibraryRoot(null) }
            assertEquals(LibraryResult.RESULT_SUCCESS, root.resultCode)
            assertEquals("root", root.value!!.mediaId)
            val top = ask { connected.getChildren("root", 0, 20, null) }
            assertEquals(listOf("now", "rooms", "library", "foryou"), top.value!!.map { it.mediaId })
            val library = ask { connected.getChildren("library", 0, 20, null) }
            assertEquals(listOf("liked", "recent", "playlists"), library.value!!.map { it.mediaId })
            val missing = ask { connected.getChildren("nowhere", 0, 20, null) }
            assertEquals(LibraryResult.RESULT_ERROR_BAD_VALUE, missing.resultCode)
        } finally {
            InstrumentationRegistry.getInstrumentation().runOnMainSync { connected.release() }
        }
    }

    @Test
    fun pickingARoomOnTheCarsScreenJoinsIt() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        var pending: ListenableFuture<MediaBrowser>? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { pending = MediaBrowser.Builder(context, token).buildAsync() }
        val connected = pending!!.get(30, TimeUnit.SECONDS)
        try {
            // The code does not name a room, so the server will say so; what is checked is that the device went to it
            val picked = MediaItem.Builder().setMediaId("room|ZZZZZ9").build()
            InstrumentationRegistry.getInstrumentation().runOnMainSync { connected.setMediaItem(picked); connected.play() }
            repeat(40) {
                if (SapocheApp.group.value?.view?.value?.roomCode == "ZZZZZ9") return@repeat
                Thread.sleep(250)
            }
            assertEquals("ZZZZZ9", SapocheApp.group.value?.view?.value?.roomCode)
        } finally {
            InstrumentationRegistry.getInstrumentation().runOnMainSync { SapocheApp.group.value?.leave(); connected.release() }
        }
    }

    @Test
    fun theRoomsOfTheAppAreReadFromItsPreferences() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val before = prefs.getString("flutter.recent_rooms", null)
        try {
            prefs.edit().putString("flutter.recent_rooms", """[{"code":"ABC123","name":"Road trip","at":5},{"code":"XYZ789","name":null,"at":4}]""").apply()
            assertEquals(listOf(CarRoom("ABC123", "Road trip", null), CarRoom("XYZ789", null, null)), CarRooms(context, okhttp3.OkHttpClient()).read())
            prefs.edit().putString("flutter.recent_rooms", "not json").apply()
            assertEquals(emptyList<CarRoom>(), CarRooms(context, okhttp3.OkHttpClient()).read())
        } finally {
            prefs.edit().apply { if (before == null) remove("flutter.recent_rooms") else putString("flutter.recent_rooms", before) }.apply()
        }
    }

    /** A browser may only be used on the main thread; the answer is waited for off it. */
    private fun <T> ask(call: () -> ListenableFuture<T>): T {
        var pending: ListenableFuture<T>? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { pending = call() }
        return pending!!.get(15, TimeUnit.SECONDS)
    }
}
