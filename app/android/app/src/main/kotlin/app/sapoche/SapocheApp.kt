package app.sapoche

import android.app.Application
import app.sapoche.core.AudioQuality
import app.sapoche.core.LyricsClient
import app.sapoche.core.LyricsStore
import app.sapoche.core.MusicClient
import app.sapoche.core.MusicFeed
import app.sapoche.core.NewPipeResolver
import app.sapoche.core.Probe
import app.sapoche.core.UpdateClient
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File

class SapocheApp : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this
        EventLog.init(filesDir)
        videoMaxHeight = getSharedPreferences("sapoche", MODE_PRIVATE).getInt("video_height", DEFAULT_VIDEO_HEIGHT)
        audioQuality = AudioQuality.of(getSharedPreferences("sapoche", MODE_PRIVATE).getInt("audio_quality", AudioQuality.MAX.level))
        language.value = getSharedPreferences("sapoche", MODE_PRIVATE).getString("language", null) ?: "en"
        resolver = NewPipeResolver(region = phoneRegion())
        streams = StreamCache(resolver, Probe())
        library = LibraryStore(this)
        val limitMb = getSharedPreferences("sapoche", MODE_PRIVATE).getInt("cache_limit_mb", DEFAULT_CACHE_MB)
        caches = MediaCaches(this, limitMb * 1024L * 1024L)
        mediaData = MediaData(caches, streams, { videoMaxHeight }, { audioQuality }) { EventLog.d("cache", it) }
        downloader = Downloader(library, mediaData::download) { EventLog.d("download", it) }
        val music = MusicClient(region = ::phoneRegion)
        musicFeed = MusicFeed(music, LyricsClient(), LyricsStore(File(cacheDir, "lyrics")))
        suggestions = SuggestionFeed(library, resolver, musicFeed) { EventLog.d("suggest", it) }
        heat = Heat(this)
        updater = Updater(this, UpdateClient(Config.SERVER, Config.authHeaders))
    }

    /** The country of the phone's settings, like "VN": what YouTube shows first follows it. */
    private fun phoneRegion(): String = java.util.Locale.getDefault().country.ifBlank { "US" }

    companion object {
        const val DEFAULT_VIDEO_HEIGHT = 720
        const val DEFAULT_CACHE_MB = 256

        /** Tallest picture to fetch; read by the loader thread, so it is volatile. */
        @Volatile
        var videoMaxHeight = DEFAULT_VIDEO_HEIGHT

        /** How much sound to fetch for a song that is not kept yet; read by the loader thread, so it is volatile. */
        @Volatile
        var audioQuality = AudioQuality.MAX

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

        /** Whether the phone is warm or saving power; work nobody waits for is put off meanwhile. */
        lateinit var heat: Heat
            private set

        /** Checks for a newer release of this app and installs it. */
        lateinit var updater: Updater
            private set

        /** Language of the few texts the native side shows itself (the notification's buttons); the UI tells it. */
        val language = MutableStateFlow("en")

        fun setLanguage(code: String) {
            language.value = code
            instance?.getSharedPreferences("sapoche", MODE_PRIVATE)?.edit()?.putString("language", code)?.apply()
        }

        private var instance: SapocheApp? = null

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
