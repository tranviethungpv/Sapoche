package app.unison

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.unison.core.TrackInfo
import app.unison.core.YoutubeLinks
import app.unison.sync.Protocol
import app.unison.sync.TrackRef
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

/**
 * Everything the Flutter UI can ask of the native side, and the stream of room state it gets back.
 * The player and the room connection live in [PlaybackService]; this only steers and observes them.
 */
class UnisonBridge(private val activity: FlutterActivity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val http = OkHttpClient()
    private val prefs = activity.getSharedPreferences("unison", android.content.Context.MODE_PRIVATE)

    private var sink: EventChannel.EventSink? = null
    private var observing: Job? = null
    private var controller: ListenableFuture<MediaController>? = null
    private var visible = false

    /** An invitation that arrived before the UI was listening. */
    private var pendingInvite: String? = null

    /** Last structural state sent, so an unchanged room is not sent again. */
    private var lastState: String? = null

    init {
        MethodChannel(messenger, "app.unison/control").setMethodCallHandler(this)
        EventChannel(messenger, "app.unison/state").setStreamHandler(this)
        connectToService()
    }

    /** Connecting a controller is what starts the playback service and keeps it bound to the UI. */
    private fun connectToService() {
        val token = SessionToken(activity, ComponentName(activity, PlaybackService::class.java))
        controller = MediaController.Builder(activity, token).buildAsync()
    }

    /** Handles a `unison://join/CODE` link; anything else is ignored. */
    fun onLink(uri: Uri?) {
        if (uri?.scheme != "unison" || uri.host != "join") return
        val code = uri.lastPathSegment?.trim()?.uppercase()?.takeIf { INVITE_CODE.matches(it) } ?: return
        if (sink != null) emit(UiJson.invite(code)) else pendingInvite = code
    }

    fun setVisible(value: Boolean) {
        visible = value
        if (value) lastState = null // a UI that just came back wants the full picture again
    }

    fun dispose() {
        observing?.cancel()
        controller?.let { MediaController.releaseFuture(it) }
        scope.cancel()
    }

    // ------------------------------------------------------------------ state stream

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        lastState = null
        pendingInvite?.let {
            pendingInvite = null
            emit(UiJson.invite(it))
        }
        observing?.cancel()
        observing = scope.launch {
            UnisonApp.group.collectLatest { group ->
                if (group == null) {
                    emit(UiJson.state(GroupController.View(), 0L))
                    return@collectLatest
                }
                coroutineScope {
                    launch {
                        group.view.collect { view ->
                            val state = UiJson.state(view, group.trimMs)
                            if (state != lastState) {
                                lastState = state
                                emit(state)
                            }
                        }
                    }
                    launch { group.errors.collect { emit(UiJson.error(it.code, it.message)) } }
                    launch {
                        while (true) {
                            if (visible) emit(UiJson.position(group.view.value, group.playerInfo()))
                            delay(POSITION_TICK_MS)
                        }
                    }
                    // Play, pause and seek should show at once instead of at the next tick
                    val listener = object : Player.Listener {
                        override fun onIsPlayingChanged(isPlaying: Boolean) = pushPosition()
                        override fun onPlaybackStateChanged(playbackState: Int) = pushPosition()
                        override fun onPositionDiscontinuity(
                            oldPosition: Player.PositionInfo,
                            newPosition: Player.PositionInfo,
                            reason: Int,
                        ) = pushPosition()

                        fun pushPosition() {
                            if (visible) emit(UiJson.position(group.view.value, group.playerInfo()))
                        }
                    }
                    group.addPlayerListener(listener)
                    try {
                        awaitCancellation()
                    } finally {
                        group.removePlayerListener(listener)
                    }
                }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        observing?.cancel()
    }

    private fun emit(json: String) {
        sink?.success(json)
    }

    // ------------------------------------------------------------------ commands

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                result.success(handle(call))
            } catch (e: NoRoomException) {
                result.error("no_room", "Not in a room", null)
            } catch (e: Exception) {
                EventLog.d("bridge", "${call.method} failed: ${e.javaClass.simpleName}: ${e.message}")
                result.error("failed", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    private class NoRoomException : Exception()

    private suspend fun handle(call: MethodCall): Any? {
        when (call.method) {
            "profile" -> return mapOf(
                "name" to prefs.getString("room_name", null),
                "device" to Build.MODEL,
                "trimMs" to prefs.getLong("trim_ms", 0L),
            )
            "search" -> return search(call.argument<String>("query").orEmpty())
            "lookup" -> return lookup(call.argument<String>("text").orEmpty())
            "share" -> {
                share(call.argument<String>("text").orEmpty())
                return null
            }
            "log" -> return EventLog.snapshot()
        }

        val group = withTimeout(SERVICE_START_TIMEOUT_MS) { UnisonApp.group.first { it != null } }!!
        when (call.method) {
            "createRoom" -> {
                val code = createRoom()
                group.join(Config.SERVER, code, call.argument<String>("name").orEmpty())
                return code
            }
            "join" -> group.join(
                Config.SERVER,
                call.argument<String>("code").orEmpty().trim().uppercase(),
                call.argument<String>("name").orEmpty(),
            )
            "leave" -> group.leave()
            "rename" -> group.rename(call.argument<String>("name").orEmpty().trim())
            "setTrim" -> {
                group.setTrim((call.argument<Number>("ms") ?: 0).toLong())
                // The trim is part of the state the UI shows, but the room itself did not change
                lastState = null
                emit(UiJson.state(group.view.value, group.trimMs))
            }
            else -> {
                if (!group.isActive) throw NoRoomException()
                when (call.method) {
                    "play" -> group.requestPlay { group.playLocally() }
                    "pause" -> group.requestPause()
                    "next" -> group.requestNext()
                    "prev" -> group.requestPrev()
                    "seek" -> group.requestSeek((call.argument<Number>("ms") ?: 0).toLong())
                    "jump" -> group.requestJump(call.argument<String>("id").orEmpty())
                    "clear" -> group.requestClearQueue()
                    "repeat" -> group.requestRepeat(call.argument<String>("mode").orEmpty())
                    "addMany" -> group.requestAddMany(
                        call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map {
                            TrackRef(
                                videoId = it["videoId"] as String,
                                title = it["title"] as String,
                                artist = it["artist"] as? String ?: "",
                                thumb = it["thumb"] as? String,
                                durMs = (it["durMs"] as? Number)?.toLong() ?: 0L,
                            )
                        },
                        call.argument<Boolean>("next") ?: false,
                    )
                    "remove" -> group.requestRemove(call.argument<String>("id").orEmpty())
                    "move" -> group.requestMove(call.argument<String>("id").orEmpty(), call.argument<Int>("to") ?: 0)
                    "add" -> group.send(
                        Protocol.queueAdd(
                            videoId = call.argument<String>("videoId").orEmpty(),
                            title = call.argument<String>("title").orEmpty(),
                            artist = call.argument<String>("artist").orEmpty(),
                            thumb = call.argument<String>("thumb"),
                            durMs = (call.argument<Number>("durMs") ?: 0).toLong(),
                            playNext = call.argument<Boolean>("next") ?: false,
                        ),
                    )
                    else -> throw UnsupportedOperationException(call.method)
                }
            }
        }
        return null
    }

    private suspend fun createRoom(): String = withContext(Dispatchers.IO) {
        val request = Request.Builder().url("${Config.SERVER}/rooms").post("".toRequestBody())
            .apply { Config.authHeaders.forEach { (k, v) -> header(k, v) } }
            .build()
        http.newCall(request).execute().use {
            check(it.isSuccessful) { "The server answered ${it.code}" }
            JSONObject(it.body.string()).getString("code")
        }
    }

    private suspend fun search(query: String): List<Map<String, Any?>> {
        if (query.isBlank()) return emptyList()
        return UnisonApp.resolver.search(query.trim(), SEARCH_LIMIT).map { it.toMap() }
    }

    /**
     * Turns pasted text into tracks: a playlist link gives its songs, a video link (or a bare video id)
     * gives one song, anything else gives null.
     */
    private suspend fun lookup(text: String): Map<String, Any?>? {
        val trimmed = text.trim()
        YoutubeLinks.playlistId(trimmed)?.let { id ->
            val playlist = UnisonApp.resolver.playlist(id, PLAYLIST_LIMIT)
            return mapOf("title" to playlist.title, "tracks" to playlist.tracks.map { it.toMap() })
        }
        val id = YoutubeLinks.videoId(trimmed) ?: return null
        return mapOf("title" to null, "tracks" to listOf(UnisonApp.resolver.resolve(id).track.toMap()))
    }

    private fun share(text: String) {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        activity.startActivity(Intent.createChooser(send, null))
    }

    private fun TrackInfo.toMap() = mapOf(
        "videoId" to videoId,
        "title" to title,
        "artist" to artist,
        "thumb" to thumbUrl,
        "durMs" to durationSec * 1000,
    )

    private companion object {
        const val POSITION_TICK_MS = 1_000L
        const val SERVICE_START_TIMEOUT_MS = 10_000L
        const val SEARCH_LIMIT = 20
        const val PLAYLIST_LIMIT = 50
        private val INVITE_CODE = Regex("[A-Z0-9]{6}")
    }
}
