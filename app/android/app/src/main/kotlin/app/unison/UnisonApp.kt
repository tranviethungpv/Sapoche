package app.unison

import android.app.Application
import app.unison.core.NewPipeResolver
import app.unison.core.Probe
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

class UnisonApp : Application() {

    override fun onCreate() {
        super.onCreate()
        EventLog.init(filesDir)
        videoMaxHeight = getSharedPreferences("unison", MODE_PRIVATE).getInt("video_height", DEFAULT_VIDEO_HEIGHT)
        resolver = NewPipeResolver()
        streams = StreamCache(resolver, Probe())
    }

    companion object {
        const val DEFAULT_VIDEO_HEIGHT = 720

        /** Tallest picture to fetch; read by the loader thread, so it is volatile. */
        @Volatile
        var videoMaxHeight = DEFAULT_VIDEO_HEIGHT

        lateinit var resolver: NewPipeResolver
            private set
        lateinit var streams: StreamCache
            private set

        private val groupFlow = MutableStateFlow<GroupController?>(null)

        /** Room connection; not null while the playback service runs. */
        val group: StateFlow<GroupController?> get() = groupFlow

        fun setGroup(value: GroupController?) {
            groupFlow.value = value
        }

        private val visibleFlow = MutableStateFlow(false)

        /** The screen is on and the app is in front; the service lets go of things when nobody looks for long. */
        val uiVisible: StateFlow<Boolean> get() = visibleFlow

        fun setUiVisible(value: Boolean) {
            visibleFlow.value = value
        }

        private val stopFlow = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

        /** The service is about to stop for being idle; the screen lets go of it so that it can. */
        val serviceStopping: SharedFlow<Unit> get() = stopFlow

        fun announceServiceStop() {
            stopFlow.tryEmit(Unit)
        }
    }
}
