package app.unison

import android.app.Application
import app.unison.core.NewPipeResolver
import app.unison.core.Probe
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class UnisonApp : Application() {

    override fun onCreate() {
        super.onCreate()
        EventLog.init(filesDir)
        resolver = NewPipeResolver()
        streams = StreamCache(resolver, Probe())
    }

    companion object {
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
    }
}
