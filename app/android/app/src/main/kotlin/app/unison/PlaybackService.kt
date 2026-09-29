package app.unison

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
import androidx.media3.datasource.ResolvingDataSource
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
import app.unison.core.OkHttpDownloader
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.io.IOException

/**
 * Owns the player and the media session. Playback runs entirely inside this foreground
 * service, so it keeps going when the activity is gone or the screen is off.
 */
class PlaybackService : MediaSessionService() {

    private var session: MediaSession? = null
    private lateinit var player: ExoPlayer
    private lateinit var group: GroupController
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** Consecutive recovery attempts per media id; reset once an item plays for a while. */
    private val recoveryAttempts = HashMap<String, Int>()

    override fun onCreate() {
        super.onCreate()

        // A plain GET without a Range header is throttled by googlevideo to roughly real-time speed
        // (~270kbps). ExoPlayer omits Range when starting at byte 0, so always send one; for later
        // seeks the data source overwrites it with the exact range.
        val http = DefaultHttpDataSource.Factory()
            .setDefaultRequestProperties(mapOf("Range" to "bytes=0-"))
            .setTransferListener(ThroughputLogger())
            .setUserAgent(OkHttpDownloader.USER_AGENT)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(20_000)
            .setAllowCrossProtocolRedirects(true)

        // "unison:<videoId>" URIs are turned into real stream URLs right when the loader opens them
        val dataSourceFactory = ResolvingDataSource.Factory(http) { spec ->
            val videoId = spec.uri.schemeSpecificPart
            when (spec.uri.scheme) {
                SCHEME -> spec.withUri(Uri.parse(UnisonApp.streams.get(videoId)))
                UnisonMediaSourceFactory.VIDEO_SCHEME ->
                    spec.withUri(Uri.parse(UnisonApp.streams.getVideo(videoId, UnisonApp.videoMaxHeight)))
                else -> spec
            }
        }

        // Large max buffer so a whole track is buffered early and the next one starts loading sooner
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(30_000, 300_000, 2_500, 5_000)
            .build()

        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(
                UnisonMediaSourceFactory(
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
            // Keeps the CPU and Wi-Fi awake while playing with the screen off
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()

        player.setPreloadConfiguration(ExoPlayer.PreloadConfiguration(10_000_000L))
        player.addListener(PlayerEvents())
        player.addAnalyticsListener(LoadEvents())

        group = GroupController(this, player, getSharedPreferences("unison", MODE_PRIVATE))
        UnisonApp.setGroup(group)
        group.rejoinSaved()

        // Notification and lock screen buttons go through this wrapper, so while joined to a room
        // they control the whole room instead of just this phone
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
                        CMD_SHUFFLE -> group.requestShuffle()
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
                .map { view -> view.roomCode?.let { view.snapshot.state?.repeat ?: "off" } }
                .distinctUntilChanged()
                .collect { mode ->
                    repeatMode = mode
                    session?.setMediaButtonPreferences(roomButtons(mode))
                }
        }

        EventLog.d("service", "created")
        main.postDelayed(heartbeat, HEARTBEAT_MS)
        if (BuildConfig.DEBUG) {
            lastWatchMs = SystemClock.elapsedRealtime()
            main.postDelayed(stallWatch, STALL_TICK_MS)
        }
    }

    /** The room's repeat mode, or null while not in a room. */
    private var repeatMode: String? = null

    private fun roomButtons(mode: String?): List<CommandButton> {
        if (mode == null) return emptyList()
        return listOf(
            CommandButton.Builder(CommandButton.ICON_SHUFFLE_OFF)
                .setDisplayName("Shuffle")
                .setSessionCommand(SessionCommand(CMD_SHUFFLE, Bundle.EMPTY))
                .build(),
            CommandButton.Builder(
                when (mode) {
                    "all" -> CommandButton.ICON_REPEAT_ALL
                    "one" -> CommandButton.ICON_REPEAT_ONE
                    else -> CommandButton.ICON_REPEAT_OFF
                },
            )
                .setDisplayName("Repeat")
                .setSessionCommand(SessionCommand(CMD_REPEAT, Bundle.EMPTY))
                .build(),
        )
    }

    private fun nextRepeat(mode: String?) = when (mode) {
        "off", null -> "all"
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
        scope.cancel()
        group.release()
        UnisonApp.setGroup(null)
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
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            EventLog.d("player", "isPlaying=$isPlaying")
            if (isPlaying) {
                // Item is healthy again once it has actually been playing for a while
                val id = currentId()
                main.postDelayed({ if (currentId() == id && player.isPlaying) recoveryAttempts.remove(id) }, 15_000)
            }
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            EventLog.d("player", "playWhenReady=$playWhenReady reason=$reason")
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            EventLog.d("player", "transition to=${mediaItem?.mediaId} reason=$reason")
        }

        override fun onPlayerError(error: PlaybackException) {
            recover(error)
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

    /**
     * Playback failed (typically a 403 from an expired or broken URL): resolve again and continue
     * from the same position. After a few failures on the same item, skip it.
     */
    private fun recover(error: PlaybackException) {
        // In a room the group session owns error handling (it must rejoin at the right position)
        if (group.isActive) return
        val id = currentId()
        val attempts = (recoveryAttempts[id] ?: 0) + 1
        recoveryAttempts[id] = attempts
        EventLog.d("recover", "item=$id attempt=$attempts error=${error.errorCodeName} cause=${error.cause?.javaClass?.simpleName}: ${error.cause?.message}")

        if (attempts > MAX_RECOVERIES) {
            EventLog.d("recover", "giving up on $id, skipping")
            recoveryAttempts.remove(id)
            if (player.hasNextMediaItem()) {
                player.seekToNextMediaItem()
                player.prepare()
            }
            return
        }

        val position = player.currentPosition
        UnisonApp.streams.invalidate(id)
        player.prepare()
        player.seekTo(position)
    }

    private fun currentId(): String = player.currentMediaItem?.mediaId ?: "-"

    /** Routes transport commands to the room while joined; behaves as the plain player otherwise. */
    private class GroupAwarePlayer(player: Player, private val group: GroupController) : ForwardingPlayer(player) {
        override fun play() {
            if (group.isActive) group.requestPlay { super.play() } else super.play()
        }

        override fun pause() {
            if (group.isActive) group.requestPause() else super.pause()
        }

        override fun setPlayWhenReady(playWhenReady: Boolean) {
            when {
                !group.isActive -> super.setPlayWhenReady(playWhenReady)
                playWhenReady -> group.requestPlay { super.setPlayWhenReady(true) }
                else -> group.requestPause()
            }
        }

        override fun seekToNext() {
            if (group.isActive) group.requestNext() else super.seekToNext()
        }

        override fun seekToNextMediaItem() {
            if (group.isActive) group.requestNext() else super.seekToNextMediaItem()
        }

        override fun seekToPrevious() {
            if (group.isActive) group.requestPrev() else super.seekToPrevious()
        }

        override fun seekToPreviousMediaItem() {
            if (group.isActive) group.requestPrev() else super.seekToPreviousMediaItem()
        }

        // The room has a queue even though the local player only ever holds one item
        override fun getAvailableCommands(): Player.Commands {
            val base = super.getAvailableCommands()
            if (!group.isActive) return base
            return base.buildUpon()
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
        const val SCHEME = "unison"
        const val CMD_SHUFFLE = "app.unison.SHUFFLE"
        const val CMD_REPEAT = "app.unison.REPEAT"
        const val HEARTBEAT_MS = 60_000L
        const val STALL_TICK_MS = 100L
        const val STALL_LOG_MS = 120L
        const val MAX_RECOVERIES = 3
    }
}
