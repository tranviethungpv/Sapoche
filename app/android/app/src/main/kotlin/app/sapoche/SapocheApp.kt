package app.sapoche

import android.app.Application
import android.os.SystemClock
import app.sapoche.core.PictureInfo
import app.sapoche.core.AudioQuality
import app.sapoche.core.Eq
import app.sapoche.core.FreshVisitors
import app.sapoche.core.InnertubePlayer
import app.sapoche.core.LyricsClient
import app.sapoche.core.LyricsStore
import app.sapoche.core.MusicClient
import app.sapoche.core.MusicFeed
import app.sapoche.core.NewPipeResolver
import app.sapoche.core.PrefetchedVisitors
import app.sapoche.core.Probe
import app.sapoche.core.QuickFirstResolver
import app.sapoche.core.SongNames
import app.sapoche.core.StreamHosts
import app.sapoche.core.UpdateClient
import app.sapoche.core.VideoPicker
import app.sapoche.sync.ListenBrainzHttp
import app.sapoche.sync.LastFmService
import app.sapoche.sync.ListenBrainzService
import app.sapoche.sync.RoomLastFmHttp
import app.sapoche.sync.Scrobbler
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File

class SapocheApp : Application() {

    override fun onCreate() {
        super.onCreate()
        Config.init(this)
        instance = this
        television = DeviceKind.isTelevision(this)
        EventLog.init(filesDir, BuildConfig.VERSION_NAME + "+" + BuildConfig.VERSION_CODE)
        CrashLog.install()
        CrashLog.readExits(this)
        StreamHosts.shared.onEvent = { EventLog.d("stream", it) }
        videoMaxHeight = getSharedPreferences("sapoche", MODE_PRIVATE).getInt("video_height", DEFAULT_VIDEO_HEIGHT)
        audioQuality = AudioQuality.of(getSharedPreferences("sapoche", MODE_PRIVATE).getInt("audio_quality", AudioQuality.MAX.level))
        eqGains = Eq.clean(getSharedPreferences("sapoche", MODE_PRIVATE).getString("eq_gains", null)?.split(",")?.mapNotNull { it.trim().toIntOrNull() })
        language.value = getSharedPreferences("sapoche", MODE_PRIVATE).getString("language", null) ?: "en"
        resolver = NewPipeResolver(region = phoneRegion())
        val innertube = InnertubePlayer(
            region = ::phoneRegion,
            visitors = PrefetchedVisitors(FreshVisitors(region = ::phoneRegion), CoroutineScope(SupervisorJob() + Dispatchers.IO)),
        )
        streams = StreamCache(QuickFirstResolver(innertube::resolve, resolver) { EventLog.d("resolve", it) }, Probe())
        library = LibraryStore(this)
        deviceMusic = DeviceMusic(this, library)
        val limitMb = getSharedPreferences("sapoche", MODE_PRIVATE).getInt("cache_limit_mb", DEFAULT_CACHE_MB)
        caches = MediaCaches(this, limitMb * 1024L * 1024L)
        loudness = LoudnessBook(library, CoroutineScope(SupervisorJob() + Dispatchers.IO))
        mediaData = MediaData(caches, streams, { pictureCeiling() }, { VideoPicker.budgetKbps(recentBestKbps, weakNetwork) }, { AudioQuality.effective(audioQuality, weakNetwork, bandwidthKbps) }, deviceMusic, loudness) { EventLog.d("cache", it) }
        downloader = Downloader(library, mediaData::download, { EventLog.d("download", it) }, ::hasInternet) { id ->
            withContext(Dispatchers.IO) { caches.downloads.removeResource(id) }
        }
        val music = MusicClient(region = ::phoneRegion)
        musicFeed = MusicFeed(music, LyricsClient(), LyricsStore(File(cacheDir, "lyrics")))
        val scrobbleScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val songNamer = { song: TrackRef -> SongNames.title(song.title, song.artist) to SongNames.credit(song.artist) }
        scrobbler = Scrobbler(
            AndroidScrobbleStorage(this), ListenBrainzService(ListenBrainzHttp(), BuildConfig.VERSION_NAME), scrobbleScope,
            namer = songNamer, mono = SystemClock::elapsedRealtime, wall = System::currentTimeMillis,
        ) { EventLog.d("scrobble", it) }.also { it.resume() }
        // Last.fm goes through the room server, which signs for the app (the secret cannot be in it)
        lastFmService = LastFmService(RoomLastFmHttp({ Config.SERVER }, { Config.authHeaders })) { EventLog.d("scrobble", it) }
        lastFm = Scrobbler(
            AndroidScrobbleStorage(this, "lastfm_session", "scrobble-lastfm.json"), lastFmService, scrobbleScope,
            namer = songNamer, mono = SystemClock::elapsedRealtime, wall = System::currentTimeMillis,
        ) { EventLog.d("scrobble", it) }.also { it.resume() }
        suggestions = SuggestionFeed(library, resolver, musicFeed) { EventLog.d("suggest", it) }
        roomKeys = RoomKeys(this)
        chatNotifier = ChatNotifier(this)
        heat = Heat(this)
        updater = Updater(this, UpdateClient(Config.SERVER, headers = { Config.authHeaders }, arm32 = android.os.Build.SUPPORTED_64_BIT_ABIS.isEmpty()))
        updateNotifier = UpdateNotifier(this)
        watchMetered()
        // The phone's decoders are listed once, now, instead of while a song waits for its picture
        Thread { PictureDecoders.maxHeight }.start()
    }

    /** Keeps [metered] true to the network, and has the picture follow it when it changes. */
    private fun watchMetered() {
        val manager = getSystemService(android.net.ConnectivityManager::class.java) ?: return
        metered = manager.isActiveNetworkMetered
        manager.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: android.net.Network, capabilities: android.net.NetworkCapabilities) {
                val now = !capabilities.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                if (now == metered) return
                metered = now
                EventLog.d("net", "metered network: $now")
                refreshPicture?.invoke()
            }
        })
    }

    /** The country of the phone's settings, like "VN": what YouTube shows first follows it. */
    private fun phoneRegion(): String = java.util.Locale.getDefault().country.ifBlank { "US" }

    /**
     * The phone reaches the internet, as the system has checked, and not only a network (a Wi-Fi with no way out is a
     * network). True when that cannot be told, so that a doubt never keeps a download from being tried.
     */
    private fun hasInternet(): Boolean {
        val manager = getSystemService(android.net.ConnectivityManager::class.java) ?: return true
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return capabilities.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    companion object {
        const val DEFAULT_VIDEO_HEIGHT = 720
        const val DEFAULT_CACHE_MB = 256

        /** Tallest picture to fetch; read by the loader thread, so it is volatile. */
        @Volatile
        var videoMaxHeight = DEFAULT_VIDEO_HEIGHT

        /** How much sound to fetch for a song that is not kept yet; read by the loader thread, so it is volatile. */
        @Volatile
        var audioQuality = AudioQuality.MAX

        /** The six bands of the equalizer in whole dB (see `Eq`); read by the sound's thread, so it is volatile and never changed in place. */
        @Volatile
        var eqGains = IntArray(Eq.BANDS)

        /** The id of the player's audio session, for the equalizer of the system; 0 until the player has one. */
        @Volatile
        var audioSessionId = 0

        /** The picture is on screen and so being loaded; read by the load control on the player's thread. */
        @Volatile
        var pictureShown = false

        /** The network is too weak for the plain rules (see `NetworkHealth`): songs are fetched in a lower quality. */
        @Volatile
        var weakNetwork = false

        /** What the player last measured the network to carry, in kbps; 0 until it measured. */
        @Volatile
        var bandwidthKbps = 0L

        /**
         * The most the network was lately measured to carry, in kbps, letting go of 15% at each new measure: the
         * player's own estimate is a median that a few small or shared transfers drag down to a fifth, and a picture
         * chosen by it would be the smallest for no reason. 0 until it measured.
         */
        @Volatile
        var recentBestKbps = 0L
            private set

        fun noteBandwidth(kbps: Long) {
            // A ceiling above 1080p waits for a measure (see VideoPicker.startCeiling); the picture goes to it by itself once there is one
            recentBestKbps = maxOf(kbps, recentBestKbps * 85 / 100)
        }

        /** The network is paid by the amount (mobile data, a hotspot of another phone): the picture stays at 1080p. */
        @Volatile
        var metered = false

        /** The tallest picture to play now: what the person chose, as far as this phone and this network allow. */
        fun pictureCeiling(): Int {
            val chosen = minOf(videoMaxHeight, PictureDecoders.maxHeight)
            return if (metered) minOf(chosen, VideoPicker.H264_MAX_HEIGHT) else chosen
        }

        fun pictureBudgetKbps(): Long = VideoPicker.budgetKbps(recentBestKbps, weakNetwork)

        /** What the screen is told of the picture that plays; see [PictureInfo]. */
        val picture = MutableStateFlow(PictureInfo())

        /** Has [picture] worked out again, on the main thread; set by the playback service. */
        @Volatile
        var refreshPicture: (() -> Unit)? = null

        lateinit var resolver: NewPipeResolver
            private set
        lateinit var streams: StreamCache
            private set

        /** How loud songs are, learned from their streams and kept in the library. */
        lateinit var loudness: LoudnessBook
            private set

        /** Liked songs and listening history; opened when first used. */
        lateinit var library: LibraryStore
            private set

        /** The music files on this phone. */
        lateinit var deviceMusic: DeviceMusic
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

        /** The secrets of the rooms with end-to-end encrypted chat. */
        lateinit var roomKeys: RoomKeys
            private set

        /** What the full player shows about a song: the radio, related songs, lyrics, the artist. */
        lateinit var musicFeed: MusicFeed
            private set

        /** Sends what this phone plays to ListenBrainz, when the person connected it; main thread only. */
        lateinit var scrobbler: Scrobbler
            private set

        /** The same for Last.fm: its own counter and queue, so that one that fails does not hold the other. */
        lateinit var lastFm: Scrobbler
            private set
        lateinit var lastFmService: LastFmService
            private set

        /** Songs to offer and to carry on with. */
        lateinit var suggestions: SuggestionFeed
            private set

        /** Whether the phone is warm or saving power; work nobody waits for is put off meanwhile. */
        lateinit var heat: Heat
            private set

        /** Tells the person of the chat while the app is not in front. */
        lateinit var chatNotifier: ChatNotifier
            private set

        /** Checks for a newer release of this app and installs it. */
        lateinit var updater: Updater
            private set

        /** Tells the person an update waits for their word when the system asks while nobody looks. */
        lateinit var updateNotifier: UpdateNotifier
            private set

        /** Language of the few texts the native side shows itself (the notification's buttons); the UI tells it. */
        val language = MutableStateFlow("en")

        fun setLanguage(code: String) {
            language.value = code
            instance?.getSharedPreferences("sapoche", MODE_PRIVATE)?.edit()?.putString("language", code)?.apply()
        }

        private var instance: SapocheApp? = null

        /** This device is a TV or a TV box: the UI draws for a screen across a room and a remote in the hand. */
        var television = false
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
            // What was said is on the screen now
            if (value) chatNotifier.clear()
        }

        private val stopFlow = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

        /** The service is about to stop for being idle; the screen lets go of it so that it can. */
        val serviceStopping: SharedFlow<Unit> get() = stopFlow

        fun announceServiceStop() {
            stopFlow.tryEmit(Unit)
        }
    }
}
