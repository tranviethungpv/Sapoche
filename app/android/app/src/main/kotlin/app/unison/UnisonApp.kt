package app.unison

import android.app.Application
import app.unison.core.LyricsClient
import app.unison.core.LyricsStore
import app.unison.core.MusicClient
import app.unison.core.MusicFeed
import app.unison.core.NewPipeResolver
import app.unison.core.Probe
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File

class UnisonApp : Application() {

    override fun onCreate() {
        super.onCreate()
        EventLog.init(filesDir)
        videoMaxHeight = getSharedPreferences("unison", MODE_PRIVATE).getInt("video_height", DEFAULT_VIDEO_HEIGHT)
        resolver = NewPipeResolver()
        streams = StreamCache(resolver, Probe())
        library = LibraryStore(this)
        val limitMb = getSharedPreferences("unison", MODE_PRIVATE).getInt("cache_limit_mb", DEFAULT_CACHE_MB)
        caches = MediaCaches(this, limitMb * 1024L * 1024L)
        mediaData = MediaData(caches, streams, { videoMaxHeight }) { EventLog.d("cache", it) }
        downloader = Downloader(library, mediaData::download) { EventLog.d("download", it) }
        val music = MusicClient()
        musicFeed = MusicFeed(music, LyricsClient(), LyricsStore(File(cacheDir, "lyrics")))
        suggestions = SuggestionFeed(library, resolver, musicFeed) { EventLog.d("suggest", it) }
    }

    companion object {
        const val DEFAULT_VIDEO_HEIGHT = 720
        const val DEFAULT_CACHE_MB = 256

        /** Tallest picture to fetch; read by the loader thread, so it is volatile. */
        @Volatile
        var videoMaxHeight = DEFAULT_VIDEO_HEIGHT

        lateinit var resolver: NewPipeResolver
            private set
        lateinit var streams: StreamCache
            private set

        /** Liked songs and listening history; opened when first used. */
        lateinit var library: LibraryStore
            private set

        /** Songs kept on disk: the downloads and what was played. */
        lateinit var caches: MediaCaches
            private set

        /** Where the player and the downloads read songs from. */
        lateinit var mediaData: MediaData
            private set

        /** Works through the songs waiting to be downloaded. */
        lateinit var downloader: Downloader
            private set

        /** What the full player shows about a song: the radio, related songs, lyrics, the artist. */
        lateinit var musicFeed: MusicFeed
            private set

        /** Songs to offer and to carry on with. */
        lateinit var suggestions: SuggestionFeed
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
