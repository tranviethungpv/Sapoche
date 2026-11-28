package app.sapoche

import android.app.PendingIntent
import android.content.Context
import android.app.Notification
import android.content.Intent
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import android.net.Uri
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.DeviceInfo
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlin.math.roundToInt

/** What the screen says of the device that plays, which this phone steers (the same fields as the `show` call of the channel). */
data class RemoteMirror(
    val device: String,
    val title: String,
    val artist: String,
    val cover: String?,
    val durationMs: Long,
    val positionMs: Long,
    val speed: Float,
    val playing: Boolean,
    /** 0..1 */
    val volume: Double,
) {
    companion object {
        fun from(map: Map<*, *>) = RemoteMirror(
            device = map["device"] as? String ?: "",
            title = map["title"] as? String ?: "",
            artist = map["artist"] as? String ?: "",
            cover = (map["cover"] as? String)?.takeIf { it.isNotBlank() },
            durationMs = (map["durationMs"] as? Number)?.toLong() ?: 0L,
            positionMs = (map["positionMs"] as? Number)?.toLong() ?: 0L,
            speed = (map["speed"] as? Number)?.toFloat() ?: 1f,
            playing = map["playing"] == true,
            volume = (map["volume"] as? Number)?.toDouble() ?: 0.5,
        )
    }
}

/**
 * The player of another device, as the system sees it: a remote playback (`PLAYBACK_TYPE_REMOTE`), so that Android gives the
 * volume keys to it, screen on or off, and Media3 builds the volume provider from [DeviceInfo]. Nothing plays here; each
 * command goes to the screen, which asks the device that plays.
 */
@UnstableApi
class RemotePlayer(looper: Looper, private val send: (String, Map<String, Any>) -> Unit) : SimpleBasePlayer(looper) {

    private var mirror: RemoteMirror? = null

    /** The volume in steps of 1/[STEPS]: what the system's bar and keys count in. */
    private var level = STEPS / 2

    fun show(next: RemoteMirror) {
        mirror = next
        level = (next.volume * STEPS).roundToInt().coerceIn(0, STEPS)
        invalidateState()
    }

    override fun getState(): State {
        val m = mirror
        val commands = Player.Commands.Builder()
            .addAll(
                COMMAND_PLAY_PAUSE,
                COMMAND_SEEK_TO_NEXT,
                COMMAND_SEEK_TO_PREVIOUS,
                COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                COMMAND_GET_METADATA,
                COMMAND_GET_CURRENT_MEDIA_ITEM,
                COMMAND_GET_TIMELINE,
                COMMAND_GET_DEVICE_VOLUME,
                COMMAND_SET_DEVICE_VOLUME_WITH_FLAGS,
                COMMAND_ADJUST_DEVICE_VOLUME_WITH_FLAGS,
            )
            .build()
        val builder = State.Builder()
            .setAvailableCommands(commands)
            .setDeviceInfo(DeviceInfo.Builder(DeviceInfo.PLAYBACK_TYPE_REMOTE).setMinVolume(0).setMaxVolume(STEPS).build())
            .setDeviceVolume(level)
        if (m == null) return builder.setPlaybackState(STATE_IDLE).build()
        val metadata = MediaMetadata.Builder()
            .setTitle(m.title)
            .setArtist(m.artist)
            .setArtworkUri(m.cover?.let(Uri::parse))
            .setIsPlayable(true)
            .build()
        val item = MediaItemData.Builder("remote")
            .setMediaItem(MediaItem.Builder().setMediaId("remote").setMediaMetadata(metadata).build())
            .setMediaMetadata(metadata)
            .setDurationUs(if (m.durationMs > 0) m.durationMs * 1000 else C.TIME_UNSET)
            .setIsSeekable(m.durationMs > 0)
            .build()
        return builder
            .setPlaylist(ImmutableList.of(item))
            .setCurrentMediaItemIndex(0)
            .setPlaybackState(STATE_READY)
            .setPlayWhenReady(m.playing, PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setContentPositionMs(PositionSupplier.getExtrapolating(m.positionMs, if (m.playing) m.speed else 0f))
            .build()
    }

    // The screen says what the device then does; the state shown is the last one the device told, until it tells another
    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        send(if (playWhenReady) "play" else "pause", emptyMap())
        mirror = mirror?.copy(playing = playWhenReady)
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        when (seekCommand) {
            COMMAND_SEEK_TO_NEXT, COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> send("next", emptyMap())
            COMMAND_SEEK_TO_PREVIOUS, COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> send("prev", emptyMap())
            else -> {
                send("seek", mapOf("ms" to positionMs))
                mirror = mirror?.copy(positionMs = positionMs)
            }
        }
        return Futures.immediateVoidFuture()
    }

    override fun handleIncreaseDeviceVolume(flags: Int): ListenableFuture<*> = nudge(1)

    override fun handleDecreaseDeviceVolume(flags: Int): ListenableFuture<*> = nudge(-1)

    override fun handleSetDeviceVolume(deviceVolume: Int, flags: Int): ListenableFuture<*> {
        level = deviceVolume.coerceIn(0, STEPS)
        send("volume", mapOf("level" to level.toDouble() / STEPS))
        return Futures.immediateVoidFuture()
    }

    /** One press of a key: the screen counts the step itself (it knows what the other device last said and what is being held). */
    private fun nudge(way: Int): ListenableFuture<*> {
        EventLog.k("connect", "volume key (session) ${if (way > 0) "up" else "down"}")
        level = (level + way).coerceIn(0, STEPS)
        send("nudge", mapOf("way" to way))
        return Futures.immediateVoidFuture()
    }

    companion object {
        /** The steps of the volume: as many as the volume keys of the screen count (`ConnectController.volumeStep` = 1/16). */
        const val STEPS = 16
    }
}

/**
 * Keeps the session of the device that plays, on this phone, for as long as it steers that one: the volume keys then reach it
 * when the screen is off or the app is not in front (they go to the session that plays, and none other of ours does). The screen
 * starts and stops it (`app.sapoche/remote_session`); it is never started from the background.
 */
@UnstableApi
class RemoteSessionService : MediaSessionService() {

    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val mirror = RemotePlayer(Looper.getMainLooper()) { name, args -> commands?.invoke(name, args) }
        player = mirror
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val built = MediaSession.Builder(this, mirror).setId("remote").setSessionActivity(openApp).build()
        session = built
        // Nobody binds to this service (it is started), so it is told of its session here: that is what makes Media3 post the
        // notification with the cover and the buttons
        addSession(built)
        // Its own notification and channel: the one of the player of this phone is another thing
        setMediaNotificationProvider(
            DefaultMediaNotificationProvider.Builder(this)
                .setNotificationId(NOTIFICATION_ID)
                .setChannelId(CHANNEL_ID)
                .setChannelName(R.string.remote_channel)
                .build()
                .also { it.setSmallIcon(R.drawable.ic_notification) },
        )
        pending?.let { mirror.show(it) }
        // A service started for the foreground must say so at once (Android stops the app that does not): the notification of
        // Media3 comes at its own time, and takes the place of this one when it does
        ServiceCompat.startForeground(this, NOTIFICATION_ID, placeholder(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        EventLog.k("connect", "remote session on")
    }

    private fun placeholder(): Notification {
        NotificationManagerCompat.from(this).createNotificationChannel(
            NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW).setName(getString(R.string.remote_channel)).build(),
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(pending?.title.orEmpty())
            .setContentText(pending?.artist.orEmpty())
            .setContentIntent(session?.sessionActivity)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        // As the player of this phone: the app swiped out of the recents ends it
        stopSelf()
    }

    override fun onDestroy() {
        EventLog.k("connect", "remote session off")
        session?.release()
        session = null
        player = null
        super.onDestroy()
    }

    companion object {
        private const val NOTIFICATION_ID = 1002
        private const val CHANNEL_ID = "remote_session"

        private var player: RemotePlayer? = null
        private var pending: RemoteMirror? = null

        /** Where the commands of the system go: the screen. */
        var commands: ((String, Map<String, Any>) -> Unit)? = null

        fun show(context: Context, mirror: RemoteMirror) {
            pending = mirror
            val live = player
            if (live != null) {
                live.show(mirror)
            } else {
                // The app is in front when it asks, which is what lets a service start (Android 12 and later)
                androidx.core.content.ContextCompat.startForegroundService(context, Intent(context, RemoteSessionService::class.java))
            }
        }

        fun hide(context: Context) {
            pending = null
            if (player != null) context.stopService(Intent(context, RemoteSessionService::class.java))
        }
    }
}
