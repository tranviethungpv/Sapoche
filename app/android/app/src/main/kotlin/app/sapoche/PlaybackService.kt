package app.sapoche

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.PowerManager
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.CommandButton
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import app.sapoche.core.OkHttpDownloader
import app.sapoche.sync.ListenSource
import app.sapoche.sync.LocalMusic
import app.sapoche.sync.IdleAction
import app.sapoche.sync.QueueFile
import app.sapoche.sync.TrackRef
import app.sapoche.sync.idleActions
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.SettableFuture
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.launch
import java.io.File
import java.io.IOException
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Owns the player and the media session. Playback runs entirely inside this foreground
 * service, so it keeps going when the activity is gone or the screen is off.
 */
class PlaybackService : MediaLibraryService() {

    private var session: MediaLibrarySession? = null
    private lateinit var player: ExoPlayer
    private lateinit var group: GroupController
    private lateinit var history: ListenHistory
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val roomsHttp = okhttp3.OkHttpClient()

    override fun onCreate() {
        super.onCreate()

        val http = SapocheApp.mediaData.httpFactory(ThroughputLogger())

        // "sapoche:<videoId>" URIs are turned into real stream URLs right when the loader opens them, and the sound
        // is read from the downloads or what was played before if it is there
        val dataSourceFactory = SapocheApp.mediaData.playerFactory(http)

        // Large max buffer so a whole track is buffered early and the next one starts loading sooner. In bytes it is
        // capped: with the picture the default allows about 144 MB, held in the app's own memory
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(30_000, 300_000, 2_500, 5_000)
            .setTargetBufferBytes(48 * 1024 * 1024)
            .build()

        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(
                SapocheMediaSourceFactory(
                    DefaultMediaSourceFactory(dataSourceFactory).setLoadErrorHandlingPolicy(PatientLoadErrorPolicy()),
                ),
            )
            .setLoadControl(loadControl)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            // Keeps the CPU and Wi-Fi awake while playing with the screen off; see updateWakeMode for songs on disk
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()

        player.setPreloadConfiguration(ExoPlayer.PreloadConfiguration(10_000_000L))
        player.addListener(PlayerEvents())
        player.addAnalyticsListener(LoadEvents())
        history = ListenHistory(
            player,
            SapocheApp.library,
            scope,
            sourceOf = { id -> if (::group.isInitialized) group.listenSource(id) else ListenSource.CHOSEN },
            leftByOther = { ::group.isInitialized && group.leftByOther() },
        ) { EventLog.d("library", it) }.also { it.start() }

        group = GroupController(
            this,
            player,
            getSharedPreferences("sapoche", MODE_PRIVATE),
            QueueFile(File(filesDir, "local_queue.json")),
        ) { seeds, exclude, count -> SapocheApp.suggestions.afterMany(seeds, exclude, count) }
        SapocheApp.setGroup(group)
        group.recoverRoom()

        // Notification and lock screen buttons go through this wrapper, so while joined to a room
        // they control the whole room instead of just this phone, and outside one the personal queue
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val steered = GroupAwarePlayer(player, group, ::playFromCar)
        val car = CarLibrary(
            SapocheApp.library,
            queue = {
                val view = group.view.value
                if (view.roomCode != null) view.snapshot.state?.queue.orEmpty() else view.local.queue
            },
            search = { query ->
                SapocheApp.resolver.search(query, 15, true).map { TrackRef(it.videoId, it.title, it.artist, it.thumbUrl, it.durationSec * 1000) }
            },
            vietnamese = { SapocheApp.language.value == "vi" },
            rooms = { CarRooms(this, roomsHttp).list() },
            suggested = { SapocheApp.suggestions.forYou() },
        )
        session = MediaLibrarySession.Builder(this, steered, object : MediaLibrarySession.Callback {
            override fun onConnect(
                mediaSession: MediaSession,
                controller: MediaSession.ControllerInfo,
            ): MediaSession.ConnectionResult {
                val commands = MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS.buildUpon()
                    .add(SessionCommand(CMD_SHUFFLE, Bundle.EMPTY))
                    .add(SessionCommand(CMD_REPEAT, Bundle.EMPTY))
                    .add(SessionCommand(CMD_LIKE, Bundle.EMPTY))
                    .build()
                return MediaSession.ConnectionResult.AcceptedResultBuilder(mediaSession)
                    .setAvailableSessionCommands(commands)
                    .setMediaButtonPreferences(buttons())
                    .build()
            }

            override fun onCustomCommand(
                mediaSession: MediaSession,
                controller: MediaSession.ControllerInfo,
                customCommand: SessionCommand,
                args: Bundle,
            ): ListenableFuture<SessionResult> {
                when (customCommand.customAction) {
                    CMD_SHUFFLE -> group.requestShuffleMode(!shuffleOn)
                    CMD_REPEAT -> group.requestRepeat(nextRepeat(repeatMode))
                    CMD_LIKE -> likeCurrent()
                }
                return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
            }

            override fun onAddMediaItems(
                mediaSession: MediaSession,
                controller: MediaSession.ControllerInfo,
                mediaItems: MutableList<MediaItem>,
            ): ListenableFuture<MutableList<MediaItem>> {
                // Controllers only send a media id; attach the URI that our data source understands
                val resolved = mediaItems.map { it.buildUpon().setUri("$SCHEME:${it.mediaId}").build() }
                return Futures.immediateFuture(resolved.toMutableList())
            }

            // A car's screen: browse the queue and the library, search by typing or by voice

            override fun onGetLibraryRoot(
                session: MediaLibrarySession,
                browser: MediaSession.ControllerInfo,
                params: LibraryParams?,
            ): ListenableFuture<LibraryResult<MediaItem>> = Futures.immediateFuture(LibraryResult.ofItem(car.root(), params))

            override fun onGetChildren(
                session: MediaLibrarySession,
                browser: MediaSession.ControllerInfo,
                parentId: String,
                page: Int,
                pageSize: Int,
                params: LibraryParams?,
            ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = answer {
                car.children(parentId)?.let { LibraryResult.ofItemList(ImmutableList.copyOf(it.drop(page * pageSize).take(pageSize)), params) }
                    ?: LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE)
            }

            override fun onGetItem(
                session: MediaLibrarySession,
                browser: MediaSession.ControllerInfo,
                mediaId: String,
            ): ListenableFuture<LibraryResult<MediaItem>> = answer {
                car.item(mediaId)?.let { LibraryResult.ofItem(it, null) } ?: LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE)
            }

            override fun onSearch(
                session: MediaLibrarySession,
                browser: MediaSession.ControllerInfo,
                query: String,
                params: LibraryParams?,
            ): ListenableFuture<LibraryResult<Void>> {
                scope.launch { session.notifySearchResultChanged(browser, query, car.find(query).size, params) }
                return Futures.immediateFuture(LibraryResult.ofVoid())
            }

            override fun onGetSearchResult(
                session: MediaLibrarySession,
                browser: MediaSession.ControllerInfo,
                query: String,
                page: Int,
                pageSize: Int,
                params: LibraryParams?,
            ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = answer {
                LibraryResult.ofItemList(ImmutableList.copyOf(car.find(query).drop(page * pageSize).take(pageSize)), params)
            }

            override fun onSetMediaItems(
                mediaSession: MediaSession,
                controller: MediaSession.ControllerInfo,
                mediaItems: MutableList<MediaItem>,
                startIndex: Int,
                startPositionMs: Long,
            ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
                val future = SettableFuture.create<MediaSession.MediaItemsWithStartPosition>()
                // Picking a room joins it; there is no song to put in the player
                CarLibrary.roomCode(mediaItems.singleOrNull() ?: MediaItem.EMPTY)?.let {
                    joinFromCar(it)
                    return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(emptyList(), C.INDEX_UNSET, C.TIME_UNSET))
                }
                scope.launch {
                    val expanded = runCatching { car.expand(mediaItems, startIndex) }.getOrNull()
                    val (items, at) = expanded ?: (mediaItems.map { it.buildUpon().setUri("$SCHEME:${it.mediaId}").build() } to startIndex)
                    future.set(MediaSession.MediaItemsWithStartPosition(items, at, startPositionMs))
                }
                return future
            }
        })
            .setSessionActivity(openApp)
            .setBitmapLoader(covers)
            .build()

        setMediaNotificationProvider(
            DefaultMediaNotificationProvider(this).also { it.setSmallIcon(R.drawable.ic_notification) },
        )

        // Shuffle and repeat sit beside the three transport buttons, which makes the notification
        // expandable: collapsed it shows the three, expanded all five
        scope.launch {
            group.view
                .map { view ->
                    if (view.roomCode != null) {
                        (view.snapshot.state?.repeat ?: "off") to (view.snapshot.state?.shuffle == true)
                    } else {
                        view.local.repeat to view.local.shuffle
                    }
                }
                .distinctUntilChanged()
                .collect { (mode, shuffle) ->
                    repeatMode = mode
                    shuffleOn = shuffle
                    refreshButtons()
                }
        }

        // The heart of a car's screen is full while the song playing is one of the liked songs, whoever liked it and from where
        currentSong.value = player.currentMediaItem?.mediaId
        scope.launch {
            combine(currentSong, SapocheApp.library.changes.onStart { emit(Unit) }) { id, _ -> id }
                .map { id -> id != null && id in SapocheApp.library.likedIds() }
                .distinctUntilChanged()
                .collect { likedNow = it; refreshButtons() }
        }

        // The cover of what comes next is fetched while this song plays, so it is there when that one starts
        scope.launch {
            group.view
                .map { view ->
                    val inRoom = view.roomCode != null
                    val queue = if (inRoom) view.snapshot.state?.queue.orEmpty() else view.local.queue
                    val index = if (inRoom) view.snapshot.state?.index ?: 0 else view.local.index
                    queue.drop(index).take(3).mapNotNull { it.thumb }
                }
                .distinctUntilChanged()
                .collect { thumbs -> thumbs.forEach { covers.prefetch(android.net.Uri.parse(it)) } }
        }

        // The widgets of the home screen follow whether it plays and where: the song itself comes with the player's events
        scope.launch { soundOn.collect { updateWidgets() } }
        scope.launch {
            group.view
                .map { view ->
                    listOf(
                        view.roomCode?.let { "${view.snapshot.state?.name ?: it}|${view.snapshot.members.count { m -> !m.away }}" },
                        widgetNext(view),
                        view.snapshot.members.filter { m -> !m.away }.take(3).map { m -> m.id },
                    )
                }
                .distinctUntilChanged()
                .collect { updateWidgets() }
        }
        // A picture that arrives after the widget was drawn is drawn in
        scope.launch { group.avatars.collect { widgetPictures = null; updateWidgets() } }

        // The car, the headset and the lock screen grey out skip and seek while this device may not move the room
        scope.launch {
            group.view.map { it.snapshot.canSteer }.distinctUntilChanged().drop(1).collect { steered.steerChanged() }
        }

        // A message, an answer or a reaction that comes while nobody looks at the app is told as a notification
        scope.launch {
            group.chatNotices.collect { notice -> if (!SapocheApp.uiVisible.value) SapocheApp.chatNotifier.show(notice) }
        }

        // The names of those buttons follow the app's language
        scope.launch {
            SapocheApp.language.drop(1).collect { session?.setMediaButtonPreferences(roomButtons(repeatMode)) }
        }

        // Nobody listening or looking for a long while: let go of what costs battery
        scope.launch {
            idleActions(
                inRoom = group.view.map { it.roomCode != null },
                playing = soundOn,
                visible = SapocheApp.uiVisible,
                roomAfterMs = ROOM_IDLE_MS,
                serviceAfterMs = SERVICE_IDLE_MS,
                // Counts the time the device sleeps, which a plain delay does not
                now = { SystemClock.elapsedRealtime() },
            ).collect { action ->
                when (action) {
                    IdleAction.SUSPEND_ROOM -> group.suspendRoom()
                    IdleAction.STOP_SERVICE -> {
                        EventLog.d("service", "idle for a long while, stopping")
                        SapocheApp.announceServiceStop()
                        stopSelf()
                    }
                }
            }
        }

        EventLog.d("service", "created")
        main.postDelayed(heartbeat, HEARTBEAT_MS)
        if (BuildConfig.DEBUG) {
            lastWatchMs = SystemClock.elapsedRealtime()
            main.postDelayed(stallWatch, STALL_TICK_MS)
        }
    }

    /**
     * A song that is wholly on disk needs no network while it plays, so the phone does not have to keep its Wi-Fi
     * awake for it: only the CPU.
     */
    private fun updateWakeMode(item: MediaItem?) {
        val local = item != null && (LocalMusic.isLocal(item.mediaId) || SapocheApp.caches.isComplete(item.mediaId))
        val mode = if (local) C.WAKE_MODE_LOCAL else C.WAKE_MODE_NETWORK
        if (mode == wakeMode) return
        wakeMode = mode
        player.setWakeMode(mode)
        EventLog.d("player", "wake mode ${if (local) "local (song is on disk)" else "network"}")
    }

    private var wakeMode = C.WAKE_MODE_NETWORK

    /** Runs [work] and gives its result as the answer to a controller's question. */
    private fun <T : Any> answer(work: suspend () -> LibraryResult<T>): ListenableFuture<LibraryResult<T>> {
        val future = SettableFuture.create<LibraryResult<T>>()
        scope.launch { future.set(runCatching { work() }.getOrElse { LibraryResult.ofError(LibraryResult.RESULT_ERROR_UNKNOWN) }) }
        return future
    }

    /**
     * A car asked for [items] to play. A song of the queue is jumped to; in a room a song is added to the room's queue
     * (the room is everybody's, a car does not replace it); otherwise the songs become the queue, from the one picked on.
     */
    private fun playFromCar(items: List<MediaItem>, startIndex: Int) {
        val at = startIndex.coerceIn(0, (items.size - 1).coerceAtLeast(0))
        val picked = items.getOrNull(at) ?: return
        val (where, what) = CarLibrary.split(picked.mediaId)
        EventLog.d("session", "a car asked to play ${picked.mediaId} (${items.size} songs from $where)")
        if (where == CarLibrary.NOW && what != null) {
            group.requestJump(what)
            return
        }
        val tracks = items.map(CarLibrary::track)
        if (group.view.value.roomCode != null) {
            group.requestAddMany(listOf(tracks[at]), true)
            return
        }
        group.requestClearQueue()
        group.requestAddMany(tracks.drop(at) + tracks.take(at), false)
    }

    /** A car picked a room of its list: this device goes into it, under the name it last used. */
    private fun joinFromCar(code: String) {
        if (group.view.value.roomCode == code) return
        EventLog.d("session", "a car asked to join room $code")
        group.join(Config.SERVER, code, group.savedName() ?: Build.MODEL, create = false)
    }

    /** Sound is playing or about to: it is being listened to, so nothing is let go of. */
    private val soundOn = MutableStateFlow(false)

    /** The pictures of the notification, the lock screen and the widgets. */
    private val covers = CoverLoader()

    private var widgetState = WidgetState()

    /** What the pictures of the widgets were made from, so they are made again only when it changes. */
    private var widgetPictures: List<Any?>? = null

    /** The songs after the one playing, with who put them on the queue, in a room. */
    private fun widgetNext(view: GroupController.View): List<WidgetRow> {
        val inRoom = view.roomCode != null
        val queue = if (inRoom) view.snapshot.state?.queue.orEmpty() else view.local.queue
        val index = if (inRoom) view.snapshot.state?.index ?: 0 else view.local.index
        return queue.drop(index + 1).take(Widgets.NEXT_ROWS).map { WidgetRow(it.id, it.title, it.artist, it.addedBy.takeIf { _ -> inRoom && it.addedBy.isNotEmpty() }) }
    }

    /** The widgets of the home screen show what plays, with the queue and the room around it. */
    private fun updateWidgets() {
        if (!Widgets.hasWidgets(this)) return
        val meta = player.mediaMetadata
        val view = group.view.value
        val listening = view.snapshot.members.filter { !it.away }
        val room = view.roomCode?.let { code -> "${view.snapshot.state?.name ?: code} · ${listening.size}" }
        val next = widgetNext(view)
        val crew = if (view.roomCode != null) listening.take(3) else emptyList()
        val state = WidgetState(
            meta.title?.toString().orEmpty(), meta.artist?.toString().orEmpty(), soundOn.value, room,
            next, crew.map { it.id }, view.roomCode,
        )
        // A room left is a room to forget: the rooms widget goes back to asking about friends
        val leftRoom = widgetState.roomCode != null && state.roomCode == null
        if (state != widgetState) {
            widgetState = state
            Widgets.update(this, state)
            if (leftRoom) RoomsWidgets.refresh(this)
        }
        val art = meta.artworkUri?.toString()
        val thumbs = view.let { v -> (if (v.roomCode != null) v.snapshot.state?.queue.orEmpty() else v.local.queue).associateBy { it.id } }
        val made = listOf(art, next.map { thumbs[it.id]?.thumb }, next.map { it.by }, crew.map { it.id }, group.picturesSeen().size)
        if (made == widgetPictures) return
        widgetPictures = made
        val names = view.snapshot.members.associate { it.id to it.name }
        val avatars = group.picturesSeen().associate { it.id to it.data }
        val ring = 0xFFFFFFFF.toInt()
        scope.launch(Dispatchers.IO) {
            fun load(url: String?) = url?.let { runCatching { covers.loadBitmap(android.net.Uri.parse(it)).get() }.getOrNull() }
            fun face(id: String): Bitmap {
                val picture = avatars[id]?.let { data ->
                    runCatching { android.util.Base64.decode(data, android.util.Base64.DEFAULT) }.getOrNull()?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                }
                return Widgets.face(id, names[id].orEmpty(), picture)
            }
            val pictures = mutableMapOf<String, Bitmap>()
            load(art)?.let {
                pictures[Widgets.COVER] = Widgets.rounded(it)
                pictures[Widgets.BLUR] = WidgetArt.tiny(it)
            }
            next.forEachIndexed { i, row ->
                load(thumbs[row.id]?.thumb)?.let { pictures[Widgets.nextCover(i)] = Widgets.rounded(it, 96, 12f) }
                row.by?.let { pictures[Widgets.adderFile(i)] = face(it) }
            }
            if (crew.isNotEmpty()) pictures[Widgets.FACES] = Widgets.faces(crew.map { face(it.id) }, ring)
            // The songs may have changed while the pictures came
            launch(Dispatchers.Main) { if (made == widgetPictures) Widgets.update(this@PlaybackService, widgetState, pictures) }
        }
    }

    private fun updateSoundOn() {
        soundOn.value = player.playWhenReady &&
            (player.playbackState == Player.STATE_BUFFERING || player.playbackState == Player.STATE_READY)
    }

    /** The repeat mode of the queue that is playing: the room's, or the personal one outside a room. */
    private var repeatMode = "off"

    /** Whether shuffle is on in the queue that is playing; the room's, or the personal one outside a room. */
    private var shuffleOn = false

    /** The id of the song playing, which the heart of a car's screen is about. */
    private val currentSong = MutableStateFlow<String?>(null)

    /** Whether the song playing is a liked one. */
    private var likedNow = false

    /**
     * The buttons beside the transport ones: shuffle, repeat and the heart. The heart is last: the notification has room for
     * five buttons and drops the sixth, as it has no use for a heart, while a car's screen lists them all.
     */
    private fun buttons(): List<CommandButton> = roomButtons(repeatMode) + likeButton()

    private fun refreshButtons() {
        session?.setMediaButtonPreferences(buttons())
    }

    private fun likeButton(): CommandButton =
        CommandButton.Builder(if (likedNow) CommandButton.ICON_HEART_FILLED else CommandButton.ICON_HEART_UNFILLED)
            .setDisplayName(
                if (SapocheApp.language.value == "vi") (if (likedNow) "Bỏ thích" else "Thích") else if (likedNow) "Unlike" else "Like",
            )
            .setSessionCommand(SessionCommand(CMD_LIKE, Bundle.EMPTY))
            .build()

    /** The heart: likes the song playing, or takes the like back, in the library of this phone. */
    private fun likeCurrent() {
        val item = player.currentMediaItem ?: return
        val track = CarLibrary.track(item)
        val liked = !likedNow
        scope.launch {
            SapocheApp.library.setLiked(track, liked)
            // As in the app, a song liked is downloaded when that is switched on
            if (liked && getSharedPreferences("sapoche", MODE_PRIVATE).getBoolean(DownloadWorker.KEY_AUTO, false)) {
                DownloadWorker.enqueue(this@PlaybackService, waiting = true)
            }
        }
    }

    private fun roomButtons(mode: String): List<CommandButton> {
        return listOf(
            CommandButton.Builder(if (shuffleOn) CommandButton.ICON_SHUFFLE_ON else CommandButton.ICON_SHUFFLE_OFF)
                .setDisplayName(if (SapocheApp.language.value == "vi") "Trộn bài" else "Shuffle")
                .setSessionCommand(SessionCommand(CMD_SHUFFLE, Bundle.EMPTY))
                .build(),
            CommandButton.Builder(
                when (mode) {
                    "all" -> CommandButton.ICON_REPEAT_ALL
                    "one" -> CommandButton.ICON_REPEAT_ONE
                    else -> CommandButton.ICON_REPEAT_OFF
                },
            )
                .setDisplayName(if (SapocheApp.language.value == "vi") "Lặp lại" else "Repeat")
                .setSessionCommand(SessionCommand(CMD_REPEAT, Bundle.EMPTY))
                .build(),
        )
    }

    private fun nextRepeat(mode: String) = when (mode) {
        "off" -> "all"
        "all" -> "one"
        else -> "off"
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the app out of the recents ends the session, as it does in YouTube Music and Spotify: the sound
        // stops and the notification goes. The queue is kept on disk, and a room is rejoined if the app is opened again soon
        EventLog.d("service", "app removed from the recents, stopping")
        SapocheApp.announceServiceStop()
        stopSelf()
    }

    override fun onDestroy() {
        EventLog.d("service", "destroyed")
        EventLog.flush()
        main.removeCallbacks(heartbeat)
        main.removeCallbacks(stallWatch)
        history.stop()
        // The widgets keep what they last showed: a service that is gone plays nothing
        Widgets.update(this, widgetState.copy(playing = false))
        scope.cancel()
        group.release()
        SapocheApp.setGroup(null)
        session?.release()
        session = null
        player.release()
        super.onDestroy()
    }

    /**
     * Notes every time the main thread was busy for a long stretch. The player and the room session
     * are driven from it, so a rotation or a heavy screen that blocks it shows up here, next to any
     * audio underrun, when the log is read afterwards. Debug builds only: it wakes ten times a second.
     */
    private var lastWatchMs = 0L
    private val stallWatch = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            val late = now - lastWatchMs - STALL_TICK_MS
            if (late > STALL_LOG_MS) {
                EventLog.d("stall", "main thread was busy for ${late}ms (playing=${player.isPlaying} pos=${player.currentPosition / 1000.0}s)")
            }
            lastWatchMs = now
            main.postDelayed(this, STALL_TICK_MS)
        }
    }

    /** Periodic proof of life, with device power state, so screen-off tests can be analysed later. */
    private val heartbeat = object : Runnable {
        override fun run() {
            val power = getSystemService(PowerManager::class.java)
            EventLog.d(
                "beat",
                "state=${stateName(player.playbackState)} playing=${player.isPlaying} " +
                    "item=${player.currentMediaItemIndex + 1}/${player.mediaItemCount} " +
                    "pos=${player.currentPosition / 1000}s/${player.duration.coerceAtLeast(0) / 1000}s " +
                    "buffered=${(player.bufferedPosition - player.currentPosition) / 1000}s " +
                    "screenOn=${power.isInteractive} idleMode=${power.isDeviceIdleMode} " +
                    "powerSave=${power.isPowerSaveMode}",
            )
            main.postDelayed(this, HEARTBEAT_MS)
        }
    }

    private inner class PlayerEvents : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            EventLog.d("player", "state=${stateName(playbackState)} item=${currentId()}")
            updateSoundOn()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            EventLog.d("player", "isPlaying=$isPlaying")
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            EventLog.d("player", "playWhenReady=$playWhenReady reason=$reason")
            updateSoundOn()
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            EventLog.d("player", "transition to=${mediaItem?.mediaId} reason=$reason")
            currentSong.value = mediaItem?.mediaId
            updateWakeMode(mediaItem)
        }

        override fun onMediaMetadataChanged(mediaMetadata: MediaMetadata) {
            updateWidgets()
        }

        override fun onPlayerError(error: PlaybackException) {
            // Recovering is up to whoever owns the queue: the room session, or the personal queue
            EventLog.d("player", "error item=${currentId()} ${error.errorCodeName} cause=${error.cause?.javaClass?.simpleName}: ${error.cause?.message}")
        }
    }

    /** Logs every loader failure, including the ones ExoPlayer retries by itself. */
    private inner class LoadEvents : AnalyticsListener {
        override fun onLoadError(
            eventTime: AnalyticsListener.EventTime,
            loadEventInfo: LoadEventInfo,
            mediaLoadData: MediaLoadData,
            error: IOException,
            wasCanceled: Boolean,
        ) {
            EventLog.d("load", "error ${error.javaClass.simpleName}: ${error.message} canceled=$wasCanceled")
        }

        override fun onLoadStarted(
            eventTime: AnalyticsListener.EventTime,
            loadEventInfo: LoadEventInfo,
            mediaLoadData: MediaLoadData,
        ) {
            EventLog.d("load", "started bufferedAhead=${(eventTime.currentPlaybackPositionMs).div(1000)}s pos")
        }

        override fun onLoadCompleted(
            eventTime: AnalyticsListener.EventTime,
            loadEventInfo: LoadEventInfo,
            mediaLoadData: MediaLoadData,
        ) {
            val kbps = if (loadEventInfo.loadDurationMs > 0) loadEventInfo.bytesLoaded * 8 / loadEventInfo.loadDurationMs else -1
            EventLog.d("load", "completed bytes=${loadEventInfo.bytesLoaded} in ${loadEventInfo.loadDurationMs}ms = ${kbps}kbps")
        }

        override fun onBandwidthEstimate(
            eventTime: AnalyticsListener.EventTime,
            totalLoadTimeMs: Int,
            totalBytesLoaded: Long,
            bitrateEstimate: Long,
        ) {
            EventLog.d("net", "bandwidth estimate=${bitrateEstimate / 1000}kbps sample=${totalBytesLoaded}B/${totalLoadTimeMs}ms")
        }

        override fun onAudioUnderrun(
            eventTime: AnalyticsListener.EventTime,
            bufferSize: Int,
            bufferSizeMs: Long,
            elapsedSinceLastFeedMs: Long,
        ) {
            EventLog.d("audio", "underrun sinceLastFeed=${elapsedSinceLastFeedMs}ms")
        }
    }

    private fun currentId(): String = player.currentMediaItem?.mediaId ?: "-"

    /**
     * Routes transport commands to whoever owns the queue: the room while joined, the personal queue
     * otherwise. The player itself only ever holds the song playing and the one after it.
     */
    private class GroupAwarePlayer(
        player: Player,
        private val group: GroupController,
        private val playFromOutside: (List<MediaItem>, Int) -> Unit,
    ) : ForwardingPlayer(player) {
        // What a controller outside the app wants played goes through the queue of the app, not straight into the player
        override fun setMediaItems(mediaItems: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long) = playFromOutside(mediaItems, startIndex)

        override fun setMediaItems(mediaItems: MutableList<MediaItem>, resetPosition: Boolean) = playFromOutside(mediaItems, 0)

        override fun setMediaItems(mediaItems: MutableList<MediaItem>) = playFromOutside(mediaItems, 0)

        override fun setMediaItem(mediaItem: MediaItem) = playFromOutside(listOf(mediaItem), 0)

        override fun setMediaItem(mediaItem: MediaItem, startPositionMs: Long) = playFromOutside(listOf(mediaItem), 0)

        override fun setMediaItem(mediaItem: MediaItem, resetPosition: Boolean) = playFromOutside(listOf(mediaItem), 0)

        override fun play() {
            EventLog.d("session", "play asked by a controller")
            group.requestPlay { super.play() }
        }

        override fun pause() {
            EventLog.d("session", "pause asked by a controller")
            group.pauseFromOutside()
        }

        override fun setPlayWhenReady(playWhenReady: Boolean) {
            EventLog.d("session", "playWhenReady=$playWhenReady asked by a controller")
            if (playWhenReady) group.requestPlay { super.setPlayWhenReady(true) } else group.pauseFromOutside()
        }

        override fun stop() {
            EventLog.d("session", "stop asked by a controller")
            group.pauseFromOutside()
        }

        override fun seekToNext() = steer("next") { group.requestNext() }

        override fun seekToNextMediaItem() = steer("next") { group.requestNext() }

        override fun seekToPrevious() = steer("previous") { group.requestPrev() }

        override fun seekToPreviousMediaItem() = steer("previous") { group.requestPrev() }

        /** What a guest of a room that only lets guests add songs may not do; the server would turn it away. */
        private fun steer(what: String, act: () -> Unit) {
            if (group.view.value.snapshot.canSteer) act() else EventLog.d("session", "$what asked by a controller, not allowed in this room")
        }

        private val controllers = CopyOnWriteArraySet<Player.Listener>()

        override fun addListener(listener: Player.Listener) {
            controllers.add(listener)
            super.addListener(listener)
        }

        override fun removeListener(listener: Player.Listener) {
            controllers.remove(listener)
            super.removeListener(listener)
        }

        /** Tells the controllers the buttons they may use changed. */
        fun steerChanged() {
            val commands = availableCommands
            controllers.forEach { it.onAvailableCommandsChanged(commands) }
        }

        override fun getAvailableCommands(): Player.Commands {
            val commands = super.getAvailableCommands().buildUpon()
                .addAll(
                    Player.COMMAND_SEEK_TO_NEXT,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                )
            if (!group.view.value.snapshot.canSteer) {
                commands.removeAll(
                    Player.COMMAND_SEEK_TO_NEXT,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                    Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                )
            }
            return commands.build()
        }

        override fun isCommandAvailable(command: Int): Boolean = availableCommands.contains(command)
    }

    private fun stateName(state: Int) = when (state) {
        Player.STATE_IDLE -> "IDLE"
        Player.STATE_BUFFERING -> "BUFFERING"
        Player.STATE_READY -> "READY"
        Player.STATE_ENDED -> "ENDED"
        else -> "?$state"
    }

    private companion object {
        const val SCHEME = "sapoche"
        const val CMD_SHUFFLE = "app.sapoche.SHUFFLE"
        const val CMD_REPEAT = "app.sapoche.REPEAT"
        const val CMD_LIKE = "app.sapoche.LIKE"
        /** Proof of life is for tests that read the log afterwards; a released app does not need to be that talkative. */
        val HEARTBEAT_MS = if (BuildConfig.DEBUG) 60_000L else 5 * 60_000L

        /** In a room, this long without sound or a look and the connection is let go of; outside one, the service. */
        const val ROOM_IDLE_MS = 20 * 60_000L
        const val SERVICE_IDLE_MS = 15 * 60_000L

        const val STALL_TICK_MS = 100L
        const val STALL_LOG_MS = 120L
    }
}
