package app.sapoche

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.net.ConnectivityManager
import android.os.Build
import android.os.SystemClock
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.sapoche.core.AudioQuality
import app.sapoche.core.Crossfade
import app.sapoche.core.Eq
import app.sapoche.core.TrackInfo
import app.sapoche.core.YoutubeLinks
import app.sapoche.sync.ChatCipher
import app.sapoche.sync.ChatQuote
import app.sapoche.sync.ListenSource
import app.sapoche.sync.LocalMusic
import app.sapoche.sync.MissedReactions
import app.sapoche.sync.Taste
import app.sapoche.sync.Scrobbler
import app.sapoche.sync.TrackRef
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.renderer.FlutterRenderer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.json.JSONObject
import java.io.IOException

/**
 * Everything the Flutter UI can ask of the native side, and the stream of room state it gets back.
 * The player and the room connection live in [PlaybackService]; this only steers and observes them.
 */
class SapocheBridge(
    private val activity: FlutterActivity,
    messenger: BinaryMessenger,
    private val renderer: FlutterRenderer,
) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val http = OkHttpClient()
    private val prefs = activity.getSharedPreferences("sapoche", android.content.Context.MODE_PRIVATE)

    private var sink: EventChannel.EventSink? = null
    private var observing: Job? = null
    private var controller: ListenableFuture<MediaController>? = null
    private val shown = MutableStateFlow(false)
    private val missedReactions = MissedReactions(SystemClock::elapsedRealtime)
    private val visible get() = shown.value

    /** An invitation that arrived before the UI was listening. */
    private var pendingInvite: String? = null
    private var pendingSetup: String? = null
    private var pendingChat: String? = null

    /** Waits for the answer of the system's dialog that asks for leave to show notifications. */
    private var noticeAnswer: kotlinx.coroutines.CompletableDeferred<Boolean>? = null

    /** Last structural state sent, so an unchanged room is not sent again. */
    private var lastState: String? = null

    /** The library changed while the screen was off; the UI is told when it comes back. */
    private var libraryDirty = false

    private val backupFiles = BackupFiles(activity, SapocheApp.library)

    private val display = SmoothDisplay(activity)

    private val outputs = AudioOutputs(activity)
    private val clipboard = ClipboardPhotos(activity)
    private val videos = VideoCompressor(activity)

    /** Where the player's picture is drawn for Flutter's Texture widget; made when first asked for. */
    private var picture: TextureRegistry.SurfaceProducer? = null

    /**
     * Takes the size listener off the player. The player outlives this bridge (the service keeps it when the screen is
     * closed), so a listener left behind keeps pushing its dead producer's surface: with the next bridge's listener
     * doing the same, each surface change reports the size again and the two swap forever, which hangs the app.
     */
    private var dropPictureListener: (() -> Unit)? = null

    private val pip = PictureInPicture(activity)

    /** The UI shows the picture. The small window shows it too, whatever the UI last said. */
    private var pictureShown = false

    init {
        MethodChannel(messenger, "app.sapoche/control").setMethodCallHandler(this)
        EventChannel(messenger, "app.sapoche/state").setStreamHandler(this)
        connectToService()
        scope.launch { SapocheApp.serviceStopping.collect { releaseService() } }
        scope.launch {
            SapocheApp.library.changes.collect {
                if (visible) emit(UiJson.library()) else libraryDirty = true
            }
        }
        // How the downloads stand is told on its own, so that a song finished does not make the screen read the library again
        scope.launch { SapocheApp.downloader.progress.collect { if (visible) emit(UiJson.downloads(it)) } }
        // The screen slows its small moving parts down while the phone is warm
        scope.launch { SapocheApp.heat.calm.collect { if (visible) emit(UiJson.calm(it, SapocheApp.heat.weak, SapocheApp.heat.veryWeak)) } }
        scope.launch { outputs.current.collect { if (visible) emit(UiJson.output(it)) } }
        // The volume goes out with the screen off too: the buttons of this phone are what the other devices of the person show
        scope.launch { outputs.volume.collect { emit(UiJson.volume(it)) } }
        // Progress of an update is only sent while somebody looks; the UI is brought up to date when it returns
        scope.launch { SapocheApp.updater.state.collect { if (visible) emit(UiJson.update(it)) } }
    }

    /** Connecting a controller is what starts the playback service and keeps it bound to the UI. */
    private fun connectToService() {
        val token = SessionToken(activity, ComponentName(activity, PlaybackService::class.java))
        controller = MediaController.Builder(activity, token).buildAsync()
    }

    /** The service stops itself after a long idle spell; when the screen comes back it is started again. */
    private fun ensureService() {
        val current = controller
        val alive = current != null && !current.isCancelled &&
            !(current.isDone && runCatching { !current.get().isConnected }.getOrDefault(true))
        if (alive) return
        current?.let { MediaController.releaseFuture(it) }
        connectToService()
    }

    /** Lets go of the service so that it can stop: a bound service lives on for as long as the screen holds it. */
    private fun releaseService() {
        controller?.let { MediaController.releaseFuture(it) }
        controller = null
    }

    /**
     * Handles an invitation, `sapoche://join/CODE` or the https link of the server's invitation page, and a setup link,
     * `sapoche://setup?server=…&key=…`, which another phone shows as a QR code, and a sync link, `sapoche://sync?k=…`; anything else is ignored. The screen checks
     * a setup link and asks before using it.
     */
    fun onLink(uri: Uri?) {
        // `sapoche://sync?k=…` carries the key of a synced library; the screen asks before it joins
        if (uri?.scheme == "sapoche" && (uri.host == "setup" || uri.host == "sync")) {
            val link = uri.toString()
            if (sink != null) emit(UiJson.setup(link)) else pendingSetup = link
            return
        }
        val own = uri?.scheme == "sapoche" && uri.host == "join"
        val web = uri?.scheme == "https" && uri.host == Uri.parse(Config.SERVER).host && uri.pathSegments.firstOrNull() == "join"
        if (uri == null || !own && !web) return
        val code = uri.lastPathSegment?.trim()?.uppercase()?.takeIf { INVITE_CODE.matches(it) } ?: return
        // The secret of a room with encrypted chat is in the link, after a # (the server never sees it) or in `k`
        val secret = uri.fragment?.split('&')?.firstOrNull { it.startsWith("k=") }?.removePrefix("k=") ?: uri.getQueryParameter("k")
        if (secret != null) acceptSecret(code, secret)
        if (sink != null) emit(UiJson.invite(code)) else pendingInvite = code
    }

    /** Keeps the [secret] (as written in an invitation link) for room [room] and lets the chat be read; false when it is not one. */
    private fun acceptSecret(room: String, secret: String): Boolean {
        val bytes = ChatCipher.decodeSecret(secret) ?: return false
        if (!INVITE_CODE.matches(room.uppercase())) return false
        SapocheApp.roomKeys.put(room, bytes)
        SapocheApp.group.value?.roomSecretChanged(room)
        return true
    }

    /** The person touched a notification of the chat of a room: its chat is what they want. */
    fun onOpenChat(intent: Intent?) {
        val room = intent?.getStringExtra(ChatNotifier.EXTRA_OPEN_CHAT)?.takeIf { INVITE_CODE.matches(it) } ?: return
        intent.removeExtra(ChatNotifier.EXTRA_OPEN_CHAT)
        if (sink != null) emit(UiJson.openChat(room)) else pendingChat = room
    }

    /** The dialog that asks for leave to show notifications closed. */
    fun onNoticePermission(requestCode: Int, grantResults: IntArray) {
        if (requestCode != NOTICE_REQUEST) return
        noticeAnswer?.complete(grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED)
        noticeAnswer = null
    }

    /** True when the phone lets the app show notifications, asking the person if it has to (from Android 13). */
    private suspend fun askForNotices(): Boolean {
        val notifier = SapocheApp.chatNotifier
        if (notifier.granted() || Build.VERSION.SDK_INT < 33) return notifier.granted()
        val answer = kotlinx.coroutines.CompletableDeferred<Boolean>()
        noticeAnswer = answer
        activity.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), NOTICE_REQUEST)
        return answer.await().also { notifier.markRefused(!it) }
    }

    /** A file picker opened for [BackupFiles] closed. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == BackupFiles.REQUEST) backupFiles.onResult(resultCode, data)
    }

    fun setVisible(value: Boolean) {
        if (value) {
            lastState = null // a UI that just came back wants the full picture again
            if (libraryDirty) {
                libraryDirty = false
                emit(UiJson.library())
            }
            ensureService()
            display.reapply()
            emit(UiJson.downloads(SapocheApp.downloader.progress.value))
            emit(UiJson.calm(SapocheApp.heat.calm.value, SapocheApp.heat.weak, SapocheApp.heat.veryWeak))
            outputs.refresh()
            emit(UiJson.output(outputs.current.value))
            emit(UiJson.volume(outputs.volume.value))
            SapocheApp.group.value?.picturesSeen()?.forEach { emit(UiJson.avatar(it)) }
            SapocheApp.group.value?.chatSeen()?.let { emit(UiJson.chat(it)) }
            missedReactions.take().forEach { emit(UiJson.reaction(it)) }
            SapocheApp.updater.refreshPermission()
            SapocheApp.updater.check(force = false)
            if (SapocheApp.updater.auto) AutoUpdateWorker.schedule(activity)
            emit(UiJson.update(SapocheApp.updater.state.value))
            SapocheApp.group.value?.resumeRoom()
            renewSuggestionsIfDue()
            if (autoDownload) DownloadWorker.enqueue(activity, waiting = true)
            scope.launch { kickOffline() }
        }
        shown.value = value
        SapocheApp.setUiVisible(value)
    }

    /** The person leaves the app: the picture they watch goes into a small window. */
    fun onUserLeaveHint() = pip.onUserLeaveHint()

    /** The app went into the small window ([on]) or came back out of it. */
    fun onPictureInPictureChanged(on: Boolean) {
        EventLog.d("video", "small window ${if (on) "open" else "closed"}")
        emit(UiJson.pip(on))
        SapocheApp.group.value?.setVideoVisible(pictureShown || on)
    }

    private val autoDownload get() = prefs.getBoolean(DownloadWorker.KEY_AUTO, false)

    /** Has the songs of kept playlists that are not on the phone yet fetched by themselves, when a playlist is kept at all. */
    private suspend fun kickOffline() {
        if (SapocheApp.library.hasOffline()) DownloadWorker.enqueueKept(activity)
    }

    /** Removes the bytes of songs taken off the list of downloads. */
    private suspend fun removeDownloaded(videoIds: List<String>) = withContext(Dispatchers.IO) {
        for (videoId in videoIds) SapocheApp.caches.downloads.removeResource(videoId)
    }

    /** On mobile data (or not knowing): songs are not fetched without asking. */
    private fun isMetered() = activity.getSystemService(ConnectivityManager::class.java)?.isActiveNetworkMetered != false

    /**
     * Brings the suggestions up to date when the person opens the app, at most twice an hour and not on a
     * metered connection: they are shown from what was kept, so there is no hurry and no reason to spend data.
     */
    private fun renewSuggestionsIfDue() {
        val now = SystemClock.elapsedRealtime()
        if (lastRenew != 0L && now - lastRenew < RENEW_EVERY_MS) return
        if (isMetered() || SapocheApp.heat.calm.value) return
        lastRenew = now
        scope.launch { SapocheApp.suggestions.renew(force = false) }
    }

    private var lastRenew = 0L

    fun dispose() {
        dropPictureListener?.invoke()
        dropPictureListener = null
        picture?.let {
            SapocheApp.group.value?.setVideoVisible(false)
            SapocheApp.group.value?.attachVideoSurface(null)
            it.release()
        }
        picture = null
        observing?.cancel()
        outputs.release()
        releaseService()
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
        pendingSetup?.let {
            pendingSetup = null
            emit(UiJson.setup(it))
        }
        pendingChat?.let {
            pendingChat = null
            emit(UiJson.openChat(it))
        }
        emit(UiJson.update(SapocheApp.updater.state.value))
        emit(UiJson.calm(SapocheApp.heat.calm.value, SapocheApp.heat.weak, SapocheApp.heat.veryWeak))
        emit(UiJson.output(outputs.current.value))
        emit(UiJson.volume(outputs.volume.value))
        observing?.cancel()
        observing = scope.launch {
            SapocheApp.group.collectLatest { group ->
                if (group == null) {
                    emit(UiJson.state(GroupController.View(), 0L, false, SapocheApp.videoMaxHeight))
                    return@collectLatest
                }
                coroutineScope {
                    launch {
                        // Drift and speed change every half second and are not part of the state. It goes out with the screen
                        // off too (the other devices of the person show it); `shown` is here so that a screen that comes back
                        // is told again (see setVisible)
                        combine(group.view.map(::structure).distinctUntilChanged(), shown, SapocheApp.picture) { view, _, _ -> view }
                            .collect { view ->
                                val state = UiJson.state(view, group.trimMs, group.videoMode, SapocheApp.videoMaxHeight, group.playbackSpeed, SapocheApp.picture.value)
                                if (state != lastState) {
                                    lastState = state
                                    emit(state)
                                }
                            }
                    }
                    launch { group.errors.collect { emit(UiJson.error(it.code, it.message)) } }
                    launch { group.notices.collect { emit(UiJson.notice(it)) } }
                    launch {
                        // A screen that starts listening is told the pictures that came while nobody looked
                        group.picturesSeen().forEach { emit(UiJson.avatar(it)) }
                        group.avatars.collect { if (visible) emit(UiJson.avatar(it)) }
                    }
                    launch {
                        // Like the pictures: the whole chat for a screen that starts listening, then what is new
                        group.chatSeen()?.let { emit(UiJson.chat(it)) }
                        group.chat.collect { if (visible) emit(UiJson.chat(it)) }
                    }
                    // A screen that is off still hears them: the ones in the pocket are told when it comes back
                    launch {
                        group.reactions.collect {
                            if (visible) emit(UiJson.reaction(it)) else missedReactions.add(it.by, it.e, it.n)
                        }
                    }
                    launch { group.sleep.state.collect { emit(UiJson.sleep(it)) } }
                    launch {
                        // No ticking at all while the screen is off, and none while the song stands still: a pause, a
                        // seek or a song that ends is pushed at once by the listener below, and a screen that comes
                        // back is told where things are
                        shown.collectLatest { on ->
                            var told = false
                            while (on) {
                                val info = group.playerInfo()
                                if (!told || info.playing) emit(UiJson.position(group.view.value, info))
                                told = true
                                delay(POSITION_TICK_MS)
                            }
                        }
                    }
                    // Play, pause and seek should show at once instead of at the next tick
                    val listener = object : Player.Listener {
                        override fun onIsPlayingChanged(isPlaying: Boolean) = pushPosition()
                        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = pushPosition()
                        override fun onPlaybackStateChanged(playbackState: Int) = pushPosition()
                        override fun onTracksChanged(tracks: androidx.media3.common.Tracks) = pushPosition()
                        override fun onPositionDiscontinuity(
                            oldPosition: Player.PositionInfo,
                            newPosition: Player.PositionInfo,
                            reason: Int,
                        ) = pushPosition()

                        // Play, pause, seek and a new song go out with the screen off too, as the state does; only the
                        // ticks between them wait for the screen
                        fun pushPosition() = emit(UiJson.position(group.view.value, group.playerInfo()))
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

    private fun structure(view: GroupController.View) =
        view.copy(snapshot = view.snapshot.copy(driftMs = null, speed = 1f))

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
            } catch (e: CodedException) {
                result.error(e.code, e.message, null)
            } catch (e: Exception) {
                EventLog.d("bridge", "${call.method} failed: ${e.javaClass.simpleName}: ${e.message}")
                result.error("failed", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    private class NoRoomException : Exception()

    /** A failure the UI has words for, by its [code] (`S.serverError` in Dart). */
    /** The panel of the equalizer the phone has of its own, for the sound of the player; null when there is none. */
    private fun systemEqualizerIntent(): Intent? {
        val intent = Intent(android.media.audiofx.AudioEffect.ACTION_DISPLAY_AUDIO_EFFECT_CONTROL_PANEL)
            .putExtra(android.media.audiofx.AudioEffect.EXTRA_PACKAGE_NAME, activity.packageName)
            .putExtra(android.media.audiofx.AudioEffect.EXTRA_AUDIO_SESSION, SapocheApp.audioSessionId)
            .putExtra(android.media.audiofx.AudioEffect.EXTRA_CONTENT_TYPE, android.media.audiofx.AudioEffect.CONTENT_TYPE_MUSIC)
        return if (intent.resolveActivity(activity.packageManager) != null) intent else null
    }

    /** The scrobbler a call is for: ListenBrainz unless it says `lastfm`. */
    private fun scrobblerOf(call: MethodCall) = if (call.argument<String>("service") == "lastfm") SapocheApp.lastFm else SapocheApp.scrobbler

    /** What the settings page shows of a service; [result] says how a connect went (`ok`, `invalid`, `pending` or `offline`). */
    private fun scrobbleMap(scrobbler: Scrobbler, result: String? = null): Map<String, Any?> {
        val status = scrobbler.status()
        return mapOf(
            "connected" to status.connected, "user" to status.user, "nowPlaying" to status.nowPlaying,
            "pending" to status.pending, "reconnect" to status.reconnect, "result" to result,
        )
    }

    private class CodedException(val code: String, message: String) : Exception(message)

    private suspend fun handle(call: MethodCall): Any? {
        when (call.method) {
            "profile" -> return mapOf(
                // Only a name the person chose: the phone's own name would be shown to everybody in the room
                "name" to prefs.getString("room_name", null),
                "device" to Build.MODEL,
                "trimMs" to prefs.getLong("trim_ms", 0L),
                "videoHeight" to SapocheApp.videoMaxHeight,
                "server" to Config.SERVER,
                "configured" to Config.isSet,
                "key" to Config.authHeaders.isNotEmpty(),
"autoplay" to prefs.getBoolean("autoplay", true),
                "shareTaste" to prefs.getBoolean("share_taste", true),
                "audioQuality" to SapocheApp.audioQuality.level,
                "normalizeVolume" to prefs.getBoolean("normalize_volume", true),
                "crossfadeSeconds" to prefs.getInt("crossfade_seconds", 0),
                "eqPreset" to (prefs.getString("eq_preset", null) ?: "off"),
                "eqGains" to SapocheApp.eqGains.toList(),
                "systemEqualizer" to (systemEqualizerIntent() != null),
            )
            "setupLink" -> return Config.setupLink()
            // The server of this build is the one built in; only the key of a build for the public is taken from the link
            "configure" -> {
                call.argument<String>("key")?.let(Config::setKey)
                return null
            }
            "cacheFolder" -> return activity.cacheDir.path
            "prepareVideo" -> {
                val made = try {
                    videos.prepare(
                        call.argument<String>("path").orEmpty(),
                        (call.argument<Number>("maxBytes") ?: 0).toLong(),
                        call.argument<Boolean>("mirror") == true,
                    )
                } catch (e: VideoCompressor.Failure) {
                    throw CodedException(e.code, e.code)
                }
                return mapOf("path" to made.path, "w" to made.w, "h" to made.h, "durMs" to made.durMs, "poster" to made.poster)
            }
            "clipboardHasPhotos" -> return clipboard.hasPhotos()
            "clipboardPhotos" -> return clipboard.read().map { mapOf("name" to it.name, "bytes" to it.bytes) }
            "smooth" -> {
                display.pace(call.argument<String>("pace") ?: "free")
                return null
            }
            "pickOutput" -> {
                outputs.pick()
                return null
            }
            "setVolume" -> {
                outputs.setVolume(call.argument<Number>("level")?.toFloat() ?: 1f)
                return null
            }
            "setLanguage" -> {
                SapocheApp.setLanguage(call.argument<String>("code") ?: "en")
                // The notes of an update come in the language that was just chosen
                if (visible) emit(UiJson.update(SapocheApp.updater.state.value))
                return null
            }
            "updateCheck" -> {
                SapocheApp.updater.check(force = true)
                return null
            }
            // Mobile data is asked about first: the file is some 30 MB
            "updateDownload" -> return if (SapocheApp.updater.download(call.argument<Boolean>("allowMetered") == true)) null else "metered"
            // "permission": Android has to be asked to let this app install first, and the UI says so
            "updateInstall" -> return if (SapocheApp.updater.install()) null else "permission"
            "updateAllowInstalls" -> {
                SapocheApp.updater.openInstallSettings()
                return null
            }
            "setAutoUpdate" -> {
                SapocheApp.updater.setAuto(call.argument<Boolean>("on") == true)
                return null
            }
            "setAutoplay" -> {
                prefs.edit().putBoolean("autoplay", call.argument<Boolean>("on") == true).apply()
                return null
            }
            "setAudioQuality" -> {
                // Songs already kept on disk stay in the stream they were fetched in (see MediaCaches), so nothing is dropped here
                val quality = AudioQuality.of((call.argument<Number>("level") ?: AudioQuality.MAX.level).toInt())
                SapocheApp.audioQuality = quality
                prefs.edit().putInt("audio_quality", quality.level).apply()
                return null
            }
            "setNormalizeVolume" -> {
                prefs.edit().putBoolean("normalize_volume", call.argument<Boolean>("on") == true).apply()
                return null
            }
            "setCrossfade" -> {
                val seconds = (call.argument<Number>("seconds") ?: 0).toInt().coerceIn(0, Crossfade.MAX_SECONDS)
                prefs.edit().putInt("crossfade_seconds", seconds).apply()
                return null
            }
            "setEqualizer" -> {
                val gains = Eq.clean(call.argument<List<Number>>("gains"))
                prefs.edit().putString("eq_preset", call.argument<String>("preset") ?: "custom")
                    .putString("eq_gains", gains.joinToString(",")).apply()
                // The sound's thread reads this at its next buffer
                SapocheApp.eqGains = gains
                EventLog.d("eq", "bands ${gains.joinToString(",")}")
                return null
            }
            "scrobbleState" -> return scrobbleMap(scrobblerOf(call))
            "scrobbleConnect" -> {
                val scrobbler = scrobblerOf(call)
                val result = scrobbler.connect(call.argument<String>("token").orEmpty())
                return scrobbleMap(scrobbler, result.name.lowercase())
            }
            "scrobbleDisconnect" -> {
                val scrobbler = scrobblerOf(call)
                scrobbler.disconnect()
                return scrobbleMap(scrobbler)
            }
            "scrobbleNowPlaying" -> {
                val scrobbler = scrobblerOf(call)
                scrobbler.setNowPlaying(call.argument<Boolean>("on") ?: true)
                return scrobbleMap(scrobbler)
            }
            // The token to allow on the page of Last.fm and the address of that page, or why there is none (`unavailable`, `offline`)
            "lastfmBegin" -> {
                val begin = SapocheApp.lastFmService.begin()
                return when {
                    begin.token != null -> mapOf("token" to begin.token, "url" to begin.url)
                    begin.unavailable -> mapOf("result" to "unavailable")
                    else -> mapOf("result" to "offline")
                }
            }
            "openSystemEqualizer" -> {
                val intent = systemEqualizerIntent() ?: return null
                activity.startActivity(intent)
                return null
            }
            "forYou" -> return SapocheApp.suggestions.forYou().map { it.toMap() }
            "refreshSuggestions" -> {
                SapocheApp.suggestions.renew(force = true)
                return SapocheApp.suggestions.forYou().map { it.toMap() }
            }
            "seedLists" -> return SapocheApp.suggestions.seedLists().map { (seed, tracks) ->
                mapOf("seed" to seed, "tracks" to tracks.map { it.toMap() })
            }
            "tasteMark" -> {
                SapocheApp.library.setTasteMark(
                    call.argument<String>("kind").orEmpty(),
                    call.argument<String>("key").orEmpty(),
                    call.argument<String>("label").orEmpty(),
                    call.argument<Boolean>("on") == true,
                )
                return null
            }
            "discover" -> return SapocheApp.suggestions.discover().map { it.toMap() }
            "tasteProfile" -> {
                val profile = SapocheApp.suggestions.profile()
                return mapOf(
                    "artists" to profile.artists.map { mapOf("key" to it.key, "label" to it.label, "score" to it.score) },
                    "songs" to profile.songs,
                    "marks" to profile.marks.map { mapOf("kind" to it.kind, "key" to it.key, "label" to it.label, "at" to it.at) },
                    "stats" to profile.stats.map { mapOf("source" to it.source, "heard" to it.heard, "skipped" to it.skipped) },
                )
            }
            "contextMix" -> {
                val (bucket, tracks) = SapocheApp.suggestions.contextMix()
                return mapOf("bucket" to bucket, "tracks" to tracks.map { it.toMap() })
            }
            "block" -> {
                // A song is blocked by its video id, an artist by the name of the first artist credited
                val artist = call.argument<String>("artist").orEmpty()
                if (call.argument<Boolean>("artistOnly") == true) {
                    SapocheApp.library.block(SuggestionFeed.ARTIST, Taste.artistKey(artist), Taste.artistLabel(artist))
                } else {
                    SapocheApp.library.block(SuggestionFeed.SONG, call.argument<String>("videoId").orEmpty(), call.argument<String>("title").orEmpty())
                }
                return null
            }
            "unblock" -> {
                SapocheApp.library.unblock(call.argument<String>("kind").orEmpty(), call.argument<String>("key").orEmpty())
                return null
            }
            "blocked" -> return SapocheApp.library.blocked().map { mapOf("kind" to it.kind, "key" to it.key, "label" to it.label) }
            "musicTrending" -> return MusicJson.shelves(SapocheApp.musicFeed.trending(SapocheApp.language.value))
            "musicHome" -> return MusicJson.home(SapocheApp.musicFeed.home(SapocheApp.language.value, call.argument<String>("params")?.ifEmpty { null }))
            "musicCharts" -> return MusicJson.shelves(SapocheApp.musicFeed.charts())
            "musicSearch" -> return SapocheApp.musicFeed.search(
                call.argument<String>("query").orEmpty(),
                call.argument<Boolean>("songs") == true,
            ).map(MusicJson::track)
            "musicNext" -> return MusicJson.next(SapocheApp.musicFeed.watchNext(call.argument<String>("videoId").orEmpty()))
            "musicViews" -> return SapocheApp.musicFeed.views(call.argument<String>("videoId").orEmpty())
            "musicRelated" -> return MusicJson.related(SapocheApp.musicFeed.related(call.argument<String>("videoId").orEmpty()))
            "musicArtist" -> return MusicJson.artist(SapocheApp.musicFeed.artist(call.argument<String>("id").orEmpty()))
            "musicSearchPage" -> return MusicJson.searchPage(
                SapocheApp.musicFeed.searchPage(call.argument<String>("query").orEmpty(), call.argument<String>("params")),
            )
            "musicSearchMore" -> return MusicJson.searchPage(SapocheApp.musicFeed.searchMore(call.argument<String>("token").orEmpty()))
            "musicCollection" -> return MusicJson.collection(SapocheApp.musicFeed.collection(call.argument<String>("id").orEmpty()))
            "musicMore" -> return MusicJson.continuation(SapocheApp.musicFeed.more(call.argument<String>("token").orEmpty()))
            "lyrics" -> return MusicJson.lyrics(
                SapocheApp.musicFeed.lyrics(
                    call.argument<String>("videoId").orEmpty(),
                    call.argument<String>("title").orEmpty(),
                    call.argument<String>("artist").orEmpty(),
                    (call.argument<Number>("durMs") ?: 0).toLong() / 1000,
                ),
            )
            // Songs likely to be touched soon: their streams are looked up ahead, unless they are on the phone already
            "warm" -> {
                SapocheApp.streams.warm(
                    call.argument<List<String>>("ids").orEmpty().filterNot { LocalMusic.isLocal(it) || SapocheApp.caches.isComplete(it) },
                )
                return null
            }
            "suggest" -> return suggest(call.argument<String>("query").orEmpty())
            "searchPlaylists" -> return searchPlaylists(call.argument<String>("query").orEmpty())
            "search" -> return search(call.argument<String>("query").orEmpty(), call.argument<Boolean>("songsOnly") == true, call.argument<Number>("limit")?.toInt() ?: SEARCH_LIMIT)
            "lookup" -> return lookup(call.argument<String>("text").orEmpty())
            "checkServer" -> return checkServer()
            "roomInfo" -> return roomInfo(call.argument<String>("code").orEmpty())
            "libraryLiked" -> return SapocheApp.library.liked().map { it.toMap() }
            "libraryRecent" -> return SapocheApp.library.recent().map { it.toMap() }
            "libraryListens" -> return SapocheApp.library.listens((call.argument<Number>("limit") ?: 600).toInt()).map { it.toMap() }
            "localStatus" -> {
                val (count, missing) = SapocheApp.library.localSummary()
                return mapOf(
                    "enabled" to prefs.getBoolean(KEY_LOCAL_ENABLED, true),
                    "access" to SapocheApp.deviceMusic.access(activity),
                    "count" to count,
                    "missing" to missing,
                )
            }
            "localEnable" -> {
                prefs.edit().putBoolean(KEY_LOCAL_ENABLED, call.argument<Boolean>("on") != false).apply()
                return null
            }
            "localAccess" -> {
                val before = SapocheApp.deviceMusic.access(activity)
                if (before == "blocked") {
                    SapocheApp.deviceMusic.openSettings(activity)
                    return before
                }
                return SapocheApp.deviceMusic.request(activity)
            }
            // An Android phone lists its own music: there is no folder of the app to copy into
            "localImport" -> return null
            "localScan" -> return mapOf("total" to SapocheApp.deviceMusic.scan(), "unsupported" to 0)
            "localTracks" -> return SapocheApp.library.localSongs().map {
                it.track.toMap() + mapOf("album" to it.album, "mime" to it.mime, "size" to it.size, "addedAt" to it.addedAt, "missing" to it.missing)
            }
            "localCover" -> return SapocheApp.deviceMusic.cover(call.argument<String>("videoId").orEmpty())
            "libraryLike" -> {
                val on = call.argument<Boolean>("on") == true
                SapocheApp.library.setLiked(trackRef(call.arguments()!!), on)
                if (on && autoDownload) DownloadWorker.enqueue(activity, waiting = true)
                return null
            }
            "downloads" -> return SapocheApp.library.downloads().map {
                it.track.toMap() + mapOf("state" to it.state, "bytes" to it.bytes)
            }
            "download" -> {
                // Songs the person asked for go on any network, but mobile data is asked about first
                if (isMetered() && call.argument<Boolean>("allowMetered") != true) return "metered"
                SapocheApp.library.requestDownloads(call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map(::trackRef))
                DownloadWorker.enqueueAsked(activity)
                return "queued"
            }
            "downloadRemove" -> {
                val videoId = call.argument<String>("videoId").orEmpty()
                SapocheApp.library.removeDownload(videoId)
                withContext(Dispatchers.IO) { SapocheApp.caches.downloads.removeResource(videoId) }
                return null
            }
            "downloadCancel" -> {
                // Only a song asked for is dropped: one fetched for the liked songs saved by themselves goes on
                val active = SapocheApp.downloader.progress.value.active?.takeIf { id ->
                    SapocheApp.library.downloads().any { it.track.videoId == id && it.state == LibraryStore.QUEUED }
                }
                DownloadWorker.cancelQueued(activity)
                // The job stops a moment after it is told to: wait for it, so that it does not write a song to a list that no longer has it
                if (active != null) withTimeoutOrNull(3000) { SapocheApp.downloader.progress.first { it.active == null } }
                SapocheApp.library.cancelQueuedDownloads()
                if (active != null) withContext(Dispatchers.IO) { SapocheApp.caches.downloads.removeResource(active) }
                return null
            }
            "downloadClear" -> {
                SapocheApp.library.clearDownloads()
                withContext(Dispatchers.IO) { SapocheApp.caches.clearDownloads() }
                return null
            }
            "storage" -> return mapOf(
                "playBytes" to SapocheApp.caches.play.cacheSpace,
                "playLimitMb" to prefs.getInt("cache_limit_mb", SapocheApp.DEFAULT_CACHE_MB),
                "downloadBytes" to SapocheApp.caches.downloads.cacheSpace,
                "downloadCount" to SapocheApp.library.downloads().count { it.state == LibraryStore.DONE },
                "autoDownload" to autoDownload,
                "offlineCellular" to prefs.getBoolean(DownloadWorker.KEY_CELLULAR, false),
            )
            "notifications" -> return SapocheApp.chatNotifier.info()
            "setNotifications" -> {
                val notifier = SapocheApp.chatNotifier
                val on = call.argument<Boolean>("on") == true
                notifier.setEnabled(on && askForNotices())
                return notifier.info()
            }
            "setNotificationPreview" -> {
                SapocheApp.chatNotifier.preview = call.argument<Boolean>("on") == true
                return null
            }
            "muteRoomNotifications" -> {
                SapocheApp.chatNotifier.mute(call.argument<String>("code").orEmpty().uppercase(), (call.argument<Number>("until"))?.toLong())
                return null
            }
            "clearPlayCache" -> {
                withContext(Dispatchers.IO) { SapocheApp.caches.clearPlay() }
                return null
            }
            "setCacheLimit" -> {
                // The size of the cache is fixed when it is opened, so this counts from the next start
                prefs.edit().putInt("cache_limit_mb", (call.argument<Number>("mb") ?: SapocheApp.DEFAULT_CACHE_MB).toInt()).apply()
                return null
            }
            "setAutoDownload" -> {
                val on = call.argument<Boolean>("on") == true
                prefs.edit().putBoolean(DownloadWorker.KEY_AUTO, on).apply()
                if (on) DownloadWorker.enqueue(activity, waiting = true) else DownloadWorker.cancelWaiting(activity)
                return null
            }
            "setOfflineCellular" -> {
                prefs.edit().putBoolean(DownloadWorker.KEY_CELLULAR, call.argument<Boolean>("on") == true).apply()
                if (SapocheApp.library.hasOffline()) DownloadWorker.enqueueKept(activity, again = true)
                return null
            }
            "playlistOffline", "folderOffline" -> {
                val on = call.argument<Boolean>("on") == true
                val remove = call.argument<Boolean>("remove") == true
                removeDownloaded(
                    if (call.method == "playlistOffline") {
                        SapocheApp.library.setPlaylistOffline(playlistId(call), on, remove, autoDownload)
                    } else {
                        SapocheApp.library.setFolderOffline(playlistId(call), on, remove, autoDownload)
                    },
                )
                if (on) kickOffline()
                return null
            }
            "offlineRemovable" -> return SapocheApp.library.offlineRemovable(
                call.argument<Number>("playlistId")?.toLong(),
                call.argument<Number>("folderId")?.toLong(),
                autoDownload,
            )
            "libraryClearHistory" -> {
                SapocheApp.library.clearHistory()
                return null
            }
            "playlists" -> return SapocheApp.library.playlists().map {
                mapOf("id" to it.id, "name" to it.name, "count" to it.count, "thumbs" to it.thumbs, "updatedAt" to it.updatedAt, "folderId" to it.folderId, "offline" to it.offline)
            }
            "folders" -> return SapocheApp.library.folders().map { mapOf("id" to it.id, "name" to it.name, "updatedAt" to it.updatedAt, "offline" to it.offline) }
            "folderCreate" -> return SapocheApp.library.createFolder(call.argument<String>("name").orEmpty())
            "folderRename" -> {
                SapocheApp.library.renameFolder(playlistId(call), call.argument<String>("name").orEmpty())
                return null
            }
            "folderDelete" -> {
                SapocheApp.library.deleteFolder(playlistId(call))
                return null
            }
            "playlistFolder" -> {
                SapocheApp.library.setPlaylistFolder(playlistId(call), call.argument<Number>("folderId")?.toLong())
                kickOffline()
                return null
            }
            "playlistTracks" -> return SapocheApp.library.playlistTracks(playlistId(call)).map { it.toMap() }
            "playlistCreate" -> return SapocheApp.library.createPlaylist(
                call.argument<String>("name").orEmpty(),
                call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map(::trackRef),
            )
            "playlistRename" -> {
                SapocheApp.library.renamePlaylist(playlistId(call), call.argument<String>("name").orEmpty())
                return null
            }
            "playlistDelete" -> {
                SapocheApp.library.deletePlaylist(playlistId(call))
                return null
            }
            "playlistAdd" -> return SapocheApp.library.addToPlaylist(
                playlistId(call),
                call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map(::trackRef),
            ).also { if (it > 0) kickOffline() }
            "playlistRemove" -> {
                SapocheApp.library.removeFromPlaylist(playlistId(call), call.argument<String>("videoId").orEmpty())
                return null
            }
            "playlistMove" -> {
                SapocheApp.library.movePlaylistItem(playlistId(call), call.argument<String>("videoId").orEmpty(), call.argument<Int>("to") ?: 0)
                return null
            }
            "backupExport" -> return backupFiles.export()?.toMap()
            "backupImport" -> {
                val restored = try {
                    backupFiles.import()
                } catch (e: LibraryBackup.FormatException) {
                    throw IllegalArgumentException(e.message)
                } ?: return null
                if (restored.liked > 0 && autoDownload) DownloadWorker.enqueue(activity, waiting = true)
                kickOffline()
                return restored.toMap()
            }
            "librarySnapshot" -> return LibraryBackup.snapshotJson(SapocheApp.library.snapshot())
            "libraryMerge" -> {
                val restored = try {
                    SapocheApp.library.restore(LibraryBackup.fromJson(call.argument<String>("json").orEmpty()))
                } catch (e: LibraryBackup.FormatException) {
                    throw IllegalArgumentException(e.message)
                }
                if (restored.liked > 0 && autoDownload) DownloadWorker.enqueue(activity, waiting = true)
                return null
            }
            // The key the server asks for goes to the sync, which sends it with its calls; it is not shown or logged
            "serverKey" -> return Config.authHeaders["X-Sapoche-Key"].orEmpty()
            "syncKey" -> return prefs.getString("sync_key", null)
            "setSyncKey" -> {
                val code = call.argument<String>("code")
                prefs.edit().apply { if (code == null) remove("sync_key") else putString("sync_key", code) }.apply()
                return null
            }
            "share" -> {
                share(call.argument<String>("text").orEmpty())
                return null
            }
            "pipSupported" -> return pip.supported
            "pipEnter" -> {
                pip.enter()
                return null
            }
            "videoWatching" -> {
                pip.setWatching(
                    call.argument<Boolean>("on") == true,
                    call.argument<Int>("width") ?: 0,
                    call.argument<Int>("height") ?: 0,
                )
                return null
            }
            "log" -> return withContext(Dispatchers.IO) { EventLog.lines() }
            "logInfo" -> return LogInfo.lines(activity)
            "logMark" -> {
                EventLog.k("mark", "the person marked this moment" + call.argument<String>("note").orEmpty().trim().let { if (it.isEmpty()) "" else ": $it" })
                return null
            }
            "logClear" -> {
                EventLog.clear()
                return null
            }
            "note" -> {
                // An error of the Dart side (ErrorLog) is an error line; the rest are the screen's own notes
                val line = call.argument<String>("line").orEmpty()
                if (line.startsWith("error: ")) EventLog.e("error", line.removePrefix("error: ")) else EventLog.d("ui", line)
                return null
            }
        }

        val group = withTimeout(SERVICE_START_TIMEOUT_MS) { SapocheApp.group.first { it != null } }!!
        when (call.method) {
            "createRoom" -> {
                if (!Config.isSet) throw CodedException("not_configured", "Set the group key first")
                val code = createRoom()
                group.join(Config.SERVER, code, call.argument<String>("name").orEmpty(), create = true)
                return code
            }
            "join" -> if (!Config.isSet) throw CodedException("not_configured", "Set the group key first") else group.join(
                Config.SERVER,
                call.argument<String>("code").orEmpty().trim().uppercase(),
                call.argument<String>("name").orEmpty(),
                create = false,
            )
            "leave" -> group.leave()
            "setShareTaste" -> {
                group.shareTasteOn = call.argument<Boolean>("on") == true
            }
            "sleep" -> when (call.argument<String>("mode")) {
                "time" -> group.sleep.startIn(call.argument<Int>("minutes") ?: 0)
                "song" -> group.sleep.startAtSongEnd()
                else -> group.sleep.cancel()
            }
            "setAvatar" -> group.setAvatar(call.argument<String>("data"))
            "rename" -> group.rename(call.argument<String>("name").orEmpty().trim())
            "setTrim" -> {
                group.setTrim((call.argument<Number>("ms") ?: 0).toLong())
                // The trim is part of the state the UI shows, but the room itself did not change
                lastState = null
                emit(UiJson.state(group.view.value, group.trimMs, group.videoMode, SapocheApp.videoMaxHeight, group.playbackSpeed, SapocheApp.picture.value))
            }
            "videoMode" -> {
                group.setVideoMode(call.argument<Boolean>("on") == true)
                lastState = null
                emit(UiJson.state(group.view.value, group.trimMs, group.videoMode, SapocheApp.videoMaxHeight, group.playbackSpeed, SapocheApp.picture.value))
            }
            "videoVisible" -> {
                pictureShown = call.argument<Boolean>("visible") == true
                group.setVideoVisible(pictureShown || pip.active)
            }
            "videoSurface" -> return videoTexture(group)
            "videoQuality" -> {
                val height = (call.argument<Number>("height") ?: SapocheApp.DEFAULT_VIDEO_HEIGHT).toInt()
                SapocheApp.videoMaxHeight = height
                prefs.edit().putInt("video_height", height).apply()
                // The song that plays goes to the new height by itself (see PictureTrackSelector), with no loading of it again
                SapocheApp.refreshPicture?.invoke()
                lastState = null
                emit(UiJson.state(group.view.value, group.trimMs, group.videoMode, SapocheApp.videoMaxHeight, group.playbackSpeed, SapocheApp.picture.value))
            }
            "playbackSpeed" -> {
                group.setPlaybackSpeed((call.argument<Number>("speed") ?: 1).toFloat())
                lastState = null
                emit(UiJson.state(group.view.value, group.trimMs, group.videoMode, SapocheApp.videoMaxHeight, group.playbackSpeed, SapocheApp.picture.value))
            }
            else -> {
                when (call.method) {
                    "solo" -> {
                        requireRoom(group)
                        if (call.argument<Boolean>("on") == true) group.goSolo() else group.rejoin()
                    }
                    "keepPlaying" -> {
                        requireRoom(group)
                        group.keepPlaying()
                    }
                    "kick" -> {
                        requireRoom(group)
                        group.requestKick(call.argument<String>("id").orEmpty())
                    }
                    "roomName" -> {
                        requireRoom(group)
                        group.requestRoomName(call.argument<String>("name").orEmpty())
                    }
                    "roomTheme" -> {
                        requireRoom(group)
                        group.requestRoomTheme(call.argument<String>("theme").orEmpty(), call.argument<String>("bg")?.takeIf { it.isNotEmpty() })
                    }
                    "roomSettings" -> {
                        requireRoom(group)
                        group.requestRoomSettings(call.argument<String>("guestControl").orEmpty())
                    }
                    "roomAutoplay" -> {
                        requireRoom(group)
                        group.requestRoomAutoplay(call.argument<Boolean>("on") == true)
                    }
                    "roomWaitWeak" -> {
                        requireRoom(group)
                        group.requestRoomWaitWeak(call.argument<Boolean>("on") == true)
                    }
                    "sendChat" -> {
                        requireRoom(group)
                        // What the message answers, as the screen shows it: a sealed room seals it with the words
                        val quote = call.argument<Map<String, Any?>>("quote")?.let {
                            ChatQuote(
                                (it["id"] as? Number)?.toLong() ?: return@let null,
                                it["by"] as? String ?: return@let null,
                                it["name"] as? String ?: return@let null,
                                it["text"] as? String ?: return@let null,
                            )
                        }
                        return group.sendChat(
                            call.argument<String>("text").orEmpty(),
                            call.argument<String>("cid").orEmpty(),
                            call.argument<Number>("reply")?.toLong(),
                            quote,
                            // What the message carries besides words, as JSON: native only passes it on, or seals it
                            call.argument<String>("extra")?.let { runCatching { Json.parseToJsonElement(it) as? JsonObject }.getOrNull() },
                        )
                    }
                    "mediaTickets" -> {
                        requireRoom(group)
                        return group.mediaTickets(call.argument<List<Number>>("sizes").orEmpty().map { it.toLong() })
                    }
                    "uploadMedia" -> return MediaHttp.put(
                        http,
                        call.argument<String>("url").orEmpty(),
                        call.argument<String>("token").orEmpty(),
                        call.argument<ByteArray>("bytes") ?: return false,
                    )
                    "downloadMedia" -> return MediaHttp.get(http, call.argument<String>("room").orEmpty(), call.argument<String>("m").orEmpty())
                    "enableEncryption" -> {
                        requireRoom(group)
                        return group.enableEncryption()
                    }
                    "roomSecret" -> {
                        requireRoom(group)
                        return group.roomSecret()
                    }
                    "setRoomSecret" -> return acceptSecret(call.argument<String>("room").orEmpty(), call.argument<String>("secret").orEmpty())
                    "reactChat" -> {
                        requireRoom(group)
                        group.reactToChat((call.argument<Number>("id") ?: 0).toLong(), call.argument<String>("e"))
                    }
                    "loadOlderChat" -> {
                        requireRoom(group)
                        return group.loadOlderChat((call.argument<Number>("before") ?: 0).toLong())
                    }
                    "readChat" -> {
                        requireRoom(group)
                        group.readChat((call.argument<Number>("upTo") ?: 0).toLong())
                    }
                    "react" -> {
                        requireRoom(group)
                        group.react(call.argument<String>("e").orEmpty(), call.argument<Int>("n") ?: 1)
                    }
                    "play" -> group.requestPlay { group.playLocally() }
                    "pause" -> group.requestPause()
                    "next" -> group.requestNext()
                    "prev" -> group.requestPrev()
                    "seek" -> group.requestSeek((call.argument<Number>("ms") ?: 0).toLong())
                    "jump" -> group.requestJump(call.argument<String>("id").orEmpty())
                    "clear" -> group.requestClearQueue()
                    "clearQueued" -> group.requestClearQueued()
                    "shuffle" -> group.requestShuffle()
                    "setShuffle" -> group.requestShuffleMode(call.argument<Boolean>("on") == true)
                    "radio" -> group.requestRadio(call.argument<String>("videoId").orEmpty())
                    "repeat" -> group.requestRepeat(call.argument<String>("mode").orEmpty())
                    "addMany" -> group.requestAddMany(
                        call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map(::trackRef),
                        call.argument<Boolean>("next") ?: false,
                        call.argument<String>("source") ?: ListenSource.CHOSEN,
                        call.argument<Boolean>("queued") ?: true,
                    )
                    "playList" -> group.requestPlayList(
                        call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map(::trackRef),
                        call.argument<Int>("start") ?: 0,
                        call.argument<String>("label"),
                        call.argument<String>("source") ?: ListenSource.CHOSEN,
                    )
                    "queueExport" -> return group.exportQueueJson()
                    "queueImport" -> return group.importQueueJson(call.argument<String>("json").orEmpty(), call.argument<Boolean>("play") == true)
                    "swap" -> group.requestSwap(call.argument<String>("id").orEmpty(), trackRef(call.argument<Map<String, Any?>>("track")!!))
                    "remove" -> group.requestRemove(call.argument<String>("id").orEmpty())
                    "move" -> group.requestMove(
                        call.argument<String>("id").orEmpty(),
                        call.argument<Int>("to") ?: 0,
                        call.argument<Boolean>("queued"),
                    )
                    "add" -> group.requestAddMany(
                        listOf(trackRef(call.arguments()!!)),
                        call.argument<Boolean>("next") ?: false,
                        call.argument<String>("source") ?: ListenSource.CHOSEN,
                    )
                    else -> throw UnsupportedOperationException(call.method)
                }
            }
        }
        return null
    }

    private fun requireRoom(group: GroupController) {
        if (!group.isActive) throw NoRoomException()
    }

    /** What the server says about a room before joining it; null when it cannot be reached. */
    private suspend fun roomInfo(code: String): Map<String, Any?>? = RoomInfo.fetch(http, code)

    /** Whether the server answers, which protocol it speaks and whether it takes the key; nothing it is asked changes anything. */
    private suspend fun checkServer(): Map<String, Any?> = withContext(Dispatchers.IO) {
        try {
            val health = http.newCall(Request.Builder().url("${Config.SERVER}/health").build()).execute().use {
                if (!it.isSuccessful) return@use null
                JSONObject(it.body.string()).optInt("protocol", -1).takeIf { protocol -> protocol >= 0 }
            }
            // The call that makes a room only draws a code, and is what asks for the key
            val key = http.newCall(
                Request.Builder().url("${Config.SERVER}/rooms").post("".toRequestBody())
                    .apply { Config.authHeaders.forEach { (k, v) -> header(k, v) } }.build(),
            ).execute().use { if (it.code == 401) false else if (it.isSuccessful) true else null }
            mapOf("reachable" to true, "protocol" to health, "keyAccepted" to key)
        } catch (e: IOException) {
            mapOf("reachable" to false, "protocol" to null, "keyAccepted" to null)
        }
    }

    private suspend fun createRoom(): String = withContext(Dispatchers.IO) {
        val request = Request.Builder().url("${Config.SERVER}/rooms").post("".toRequestBody())
            .apply { Config.authHeaders.forEach { (k, v) -> header(k, v) } }
            .build()
        http.newCall(request).execute().use {
            if (it.code == 401) throw CodedException("key_refused", "The server turned the key down")
            if (it.code == 429) throw CodedException("server_busy", "The server asked to wait a minute")
            check(it.isSuccessful) { "The server answered ${it.code}" }
            JSONObject(it.body.string()).getString("code")
        }
    }

    private suspend fun search(query: String, songsOnly: Boolean, limit: Int): List<Map<String, Any?>> {
        if (query.isBlank()) return emptyList()
        return SapocheApp.resolver.search(query.trim(), limit, songsOnly).map { it.toMap() }
    }

    /** Completions of a half-typed search; empty when YouTube cannot be reached, since they are only a help. */
    private suspend fun suggest(query: String): List<String> {
        if (query.isBlank()) return emptyList()
        return try {
            SapocheApp.resolver.suggest(query.trim()).take(SUGGESTION_LIMIT)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyList()
        }
    }

    private suspend fun searchPlaylists(query: String): List<Map<String, Any?>> {
        if (query.isBlank()) return emptyList()
        return SapocheApp.resolver.searchPlaylists(query.trim(), SEARCH_LIMIT).map {
            mapOf(
                "id" to it.id,
                "title" to it.title,
                "uploader" to it.uploader,
                "thumb" to it.thumbUrl,
                "count" to it.songCount,
            )
        }
    }

    /**
     * The texture Flutter draws the picture from. The player renders into its surface; the texture
     * is resized to the picture so it is not scaled twice. Returns the texture id for the Texture widget.
     */
    private fun videoTexture(group: GroupController): Long {
        picture?.let { return it.id() }
        val producer = renderer.createSurfaceProducer()
        producer.setSize(VIDEO_DEFAULT_WIDTH, VIDEO_DEFAULT_HEIGHT)
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() = group.attachVideoSurface(producer.surface)
            override fun onSurfaceCleanup() = group.attachVideoSurface(null)
        })
        group.attachVideoSurface(producer.surface)
        val sizeListener = object : Player.Listener {
            override fun onVideoSizeChanged(size: androidx.media3.common.VideoSize) {
                if (size.width <= 0 || size.height <= 0) return
                producer.setSize(size.width, size.height)
                group.attachVideoSurface(producer.surface)
            }
        }
        group.addPlayerListener(sizeListener)
        dropPictureListener = { group.removePlayerListener(sizeListener) }
        picture = producer
        return producer.id()
    }

    /**
     * Turns pasted text into tracks: a playlist link gives its songs, a video link (or a bare video id)
     * gives one song, anything else gives null.
     */
    private suspend fun lookup(text: String): Map<String, Any?>? {
        val trimmed = text.trim()
        YoutubeLinks.playlistId(trimmed)?.let { id ->
            val playlist = SapocheApp.resolver.playlist(id, PLAYLIST_LIMIT)
            return mapOf("title" to playlist.title, "tracks" to playlist.tracks.map { it.toMap() })
        }
        val id = YoutubeLinks.videoId(trimmed) ?: return null
        return mapOf("title" to null, "tracks" to listOf(SapocheApp.resolver.resolve(id).track.toMap()))
    }

    private fun share(text: String) {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        activity.startActivity(Intent.createChooser(send, null))
    }

    private fun LibraryStore.Restored.toMap() = mapOf("liked" to liked, "playlists" to playlists, "listens" to listens, "local" to skippedLocal)

    private fun playlistId(call: MethodCall): Long = call.argument<Number>("id")!!.toLong()

    /** A song as the UI sends it. */
    private fun trackRef(map: Map<String, Any?>) = TrackRef(
        videoId = map["videoId"] as String,
        title = map["title"] as String,
        artist = map["artist"] as? String ?: "",
        thumb = map["thumb"] as? String,
        durMs = (map["durMs"] as? Number)?.toLong() ?: 0L,
        explicit = map["explicit"] == true,
        year = map["year"] as? String,
    )

    private fun TrackRef.toMap() = mapOf(
        "videoId" to videoId,
        "title" to title,
        "artist" to artist,
        "thumb" to thumb,
        "durMs" to durMs,
        "explicit" to explicit,
        "year" to year,
    )

    private fun LibraryStore.Entry.toMap() = mapOf(
        "videoId" to track.videoId,
        "title" to track.title,
        "artist" to track.artist,
        "thumb" to track.thumb,
        "durMs" to track.durMs,
        "explicit" to track.explicit,
        "year" to track.year,
        "at" to at,
        "plays" to plays,
    )

    private fun TrackInfo.toMap() = mapOf(
        "videoId" to videoId,
        "title" to title,
        "artist" to artist,
        "thumb" to thumbUrl,
        "durMs" to durationSec * 1000,
    )

    private companion object {
        const val KEY_LOCAL_ENABLED = "local_enabled"
        const val POSITION_TICK_MS = 1_000L
        const val SERVICE_START_TIMEOUT_MS = 10_000L
        const val SEARCH_LIMIT = 20
        const val SUGGESTION_LIMIT = 6
        const val RENEW_EVERY_MS = 30 * 60_000L
        const val PLAYLIST_LIMIT = 500
        const val VIDEO_DEFAULT_WIDTH = 1280
        const val VIDEO_DEFAULT_HEIGHT = 720
        private val INVITE_CODE = Regex("[A-Z0-9]{6}")

        /** Request code of the dialog that asks for leave to show notifications. */
        const val NOTICE_REQUEST = 4713
    }
}
