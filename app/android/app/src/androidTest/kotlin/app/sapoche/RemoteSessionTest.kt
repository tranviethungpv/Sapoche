package app.sapoche

import android.content.ComponentName
import android.os.Looper
import androidx.media3.common.DeviceInfo
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The session of the device that this phone steers: the system gives the volume keys to a remote playback that plays, and
 * what it asks of it must go to the screen (which asks the other device).
 */
class RemoteSessionTest {

    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val sent = mutableListOf<Pair<String, Map<String, Any>>>()
    private val sentLock = Any()

    private fun mirror(playing: Boolean = true, volume: Double = 0.5) = RemoteMirror(
        device = "Living room",
        title = "Song",
        artist = "Artist · Playing on Living room",
        cover = null,
        durationMs = 200_000,
        positionMs = 30_000,
        speed = 1f,
        playing = playing,
        volume = volume,
    )

    private fun onMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    private fun player(): RemotePlayer {
        var made: RemotePlayer? = null
        onMain {
            made = RemotePlayer(Looper.getMainLooper()) { name, args -> synchronized(sentLock) { sent += name to args } }
            made!!.show(mirror())
        }
        return made!!
    }

    @Before
    fun clean() {
        sent.clear()
        RemoteSessionService.commands = null
    }

    @After
    fun stop() {
        onMain { RemoteSessionService.hide(context) }
        RemoteSessionService.commands = null
    }

    @Test
    fun theOtherDeviceIsARemotePlaybackWithTheVolumeInSteps() {
        val p = player()
        onMain {
            assertEquals(DeviceInfo.PLAYBACK_TYPE_REMOTE, p.deviceInfo.playbackType)
            assertEquals(0, p.deviceInfo.minVolume)
            assertEquals(RemotePlayer.STEPS, p.deviceInfo.maxVolume)
            assertEquals(8, p.deviceVolume)
            assertTrue(p.isPlaying)
            assertEquals("Song", p.mediaMetadata.title)
            assertEquals(200_000L, p.duration)
        }
    }

    @Test
    fun theKeysAndTheBarOfTheSystemGoToTheScreen() {
        val p = player()
        onMain {
            p.increaseDeviceVolume(0)
            p.decreaseDeviceVolume(0)
            p.setDeviceVolume(4, 0)
        }
        synchronized(sentLock) {
            assertEquals(listOf("nudge", "nudge", "volume"), sent.map { it.first })
            assertEquals(1, sent[0].second["way"])
            assertEquals(-1, sent[1].second["way"])
            assertEquals(0.25, sent[2].second["level"] as Double, 0.0001)
        }
    }

    @Test
    fun theButtonsOfTheNotificationAndTheLockScreenGoToTheScreen() {
        val p = player()
        onMain {
            p.pause()
            p.play()
            p.seekToNext()
            p.seekToPrevious()
            p.seekTo(45_000)
        }
        synchronized(sentLock) {
            val names = sent.map { it.first }
            assertEquals(listOf("pause", "play", "next", "prev", "seek"), names)
            assertEquals(45_000L, sent.last().second["ms"])
        }
    }

    @Test
    fun theServiceShowsTheOtherDeviceToTheSystem() {
        val commands = mutableListOf<String>()
        RemoteSessionService.commands = { name, _ -> synchronized(commands) { commands += name } }
        onMain { RemoteSessionService.show(context, mirror()) }
        val token = SessionToken(context, ComponentName(context, RemoteSessionService::class.java))
        val controller = MediaController.Builder(context, token).buildAsync().get(10, TimeUnit.SECONDS)
        try {
            var type = -1
            var volume = -1
            var title: CharSequence? = null
            var state = Player.STATE_IDLE
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                type = controller.deviceInfo.playbackType
                volume = controller.deviceVolume
                title = controller.mediaMetadata.title
                state = controller.playbackState
            }
            assertEquals(DeviceInfo.PLAYBACK_TYPE_REMOTE, type)
            assertEquals(8, volume)
            assertEquals("Song", title)
            assertEquals(Player.STATE_READY, state)
            // A command of the controller reaches the screen
            InstrumentationRegistry.getInstrumentation().runOnMainSync { controller.increaseDeviceVolume(0) }
            Thread.sleep(500)
            synchronized(commands) { assertEquals(listOf("nudge"), commands) }
        } finally {
            InstrumentationRegistry.getInstrumentation().runOnMainSync { controller.release() }
        }
    }
}
