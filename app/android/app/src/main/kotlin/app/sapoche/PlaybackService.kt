package app.sapoche

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.PowerManager
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
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
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import app.sapoche.core.OkHttpDownloader
import app.sapoche.sync.IdleAction
import app.sapoche.sync.QueueFile
import app.sapoche.sync.idleActions
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.io.File
import java.io.IOException

/**
 * Owns the player and the media session. Playback runs entirely inside this foreground
 * service, so it keeps going when the activity is gone or the screen is off.
 */
class PlaybackService : MediaSessionService() {

    private var session: MediaSession? = null
    private lateinit var player: ExoPlayer
    private lateinit var group: GroupController
    private lateinit var history: ListenHistory
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

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
        history = ListenHistory(player, SapocheApp.library, scope) { EventLog.d("library", it) }.also { it.start() }

        group = GroupController(
            this,
            player,
            getSharedPreferences("sapoche", MODE_PRIVATE),
            QueueFile(File(filesDir, "local_queue.json")),
        ) { videoId, exclude, count -> SapocheApp.suggestions.after(videoId, exclude, count) }
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
        session = MediaSession.Builder(this, GroupAwarePlayer(player, group))
            .setSessionActivity(openApp)
            .setBitmapLoader(CoverLoader())
            .setCallback(object : MediaSession.Callback {
                override fun onConnect(
                    mediaSession: MediaSession,
                    controller: MediaSession.ControllerInfo,
                ): MediaSession.ConnectionResult {
                    val commands = MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                        .add(SessionCommand(CMD_SHUFFLE, Bundle.EMPTY))
                        .add(SessionCommand(CMD_REPEAT, Bundle.EMPTY))
                        .build()
                    return MediaSession.ConnectionResult.AcceptedResultBuilder(mediaSession)
                        .setAvailableSessionCommands(commands)
                        .setMediaButtonPreferences(roomButtons(repeatMode))
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
            })
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
                    session?.setMediaButtonPreferences(roomButtons(mode))
                }
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
        val local = item != null && SapocheApp.caches.isComplete(item.mediaId)
        val mode = if (local) C.WAKE_MODE_LOCAL else C.WAKE_MODE_NETWORK
        if (mode == wakeMode) return
        wakeMode = mode
        player.setWakeMode(mode)
        EventLog.d("player", "wake mode ${if (local) "local (song is on disk)" else "network"}")
    }

    private var wakeMode = C.WAKE_MODE_NETWORK

    /** Sound is playing or about to: it is being listened to, so nothing is let go of. */
    private val soundOn = MutableStateFlow(false)

    private fun updateSoundOn() {
        soundOn.value = player.playWhenReady &&
            (player.playbackState == Player.STATE_BUFFERING || player.playbackState == Player.STATE_READY)
    }

    /** The repeat mode of the queue that is playing: the room's, or the personal one outside a room. */
    private var repeatMode = "off"

    /** Whether shuffle is on in the queue that is playing; the room's, or the personal one outside a room. */
    private var shuffleOn = false

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

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the app away should not stop music that is playing or a room we are part of
        if (group.isActive) return
        if (!player.playWhenReady || player.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        EventLog.d("service", "destroyed")
        EventLog.flush()
        main.removeCallbacks(heartbeat)
        main.removeCallbacks(stallWatch)
        history.stop()
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
            updateWakeMode(mediaItem)
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
    private class GroupAwarePlayer(player: Player, private val group: GroupController) : ForwardingPlayer(player) {
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

        override fun seekToNext() {
            group.requestNext()
        }

        override fun seekToNextMediaItem() {
            group.requestNext()
        }

        override fun seekToPrevious() {
            group.requestPrev()
        }

        override fun seekToPreviousMediaItem() {
            group.requestPrev()
        }

        override fun getAvailableCommands(): Player.Commands {
            return super.getAvailableCommands().buildUpon()
                .addAll(
                    Player.COMMAND_SEEK_TO_NEXT,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                )
                .build()
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
        /** Proof of life is for tests that read the log afterwards; a released app does not need to be that talkative. */
        val HEARTBEAT_MS = if (BuildConfig.DEBUG) 60_000L else 5 * 60_000L

        /** In a room, this long without sound or a look and the connection is let go of; outside one, the service. */
        const val ROOM_IDLE_MS = 20 * 60_000L
        const val SERVICE_IDLE_MS = 15 * 60_000L

        const val STALL_TICK_MS = 100L
        const val STALL_LOG_MS = 120L
    }
}
