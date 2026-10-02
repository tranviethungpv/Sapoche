package app.unison

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.net.ConnectivityManager
import android.os.Build
import android.os.SystemClock
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.unison.core.TrackInfo
import app.unison.core.YoutubeLinks
import app.unison.sync.TrackRef
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
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
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
class UnisonBridge(
    private val activity: FlutterActivity,
    messenger: BinaryMessenger,
    private val renderer: FlutterRenderer,
) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val http = OkHttpClient()
    private val prefs = activity.getSharedPreferences("unison", android.content.Context.MODE_PRIVATE)

    private var sink: EventChannel.EventSink? = null
    private var observing: Job? = null
    private var controller: ListenableFuture<MediaController>? = null
    private val shown = MutableStateFlow(false)
    private val visible get() = shown.value

    /** An invitation that arrived before the UI was listening. */
    private var pendingInvite: String? = null

    /** Last structural state sent, so an unchanged room is not sent again. */
    private var lastState: String? = null

    /** The library changed while the screen was off; the UI is told when it comes back. */
    private var libraryDirty = false

    private val backupFiles = BackupFiles(activity, UnisonApp.library)

    private val display = SmoothDisplay(activity)

    private val outputs = AudioOutputs(activity)

    /** Where the player's picture is drawn for Flutter's Texture widget; made when first asked for. */
    private var picture: TextureRegistry.SurfaceProducer? = null

    init {
        MethodChannel(messenger, "app.unison/control").setMethodCallHandler(this)
        EventChannel(messenger, "app.unison/state").setStreamHandler(this)
        connectToService()
        scope.launch { UnisonApp.serviceStopping.collect { releaseService() } }
        scope.launch {
            UnisonApp.library.changes.collect {
                if (visible) emit(UiJson.library()) else libraryDirty = true
            }
        }
        // The screen slows its small moving parts down while the phone is warm
        scope.launch { UnisonApp.heat.calm.collect { if (visible) emit(UiJson.calm(it)) } }
        scope.launch { outputs.current.collect { if (visible) emit(UiJson.output(it)) } }
        // Progress of an update is only sent while somebody looks; the UI is brought up to date when it returns
        scope.launch { UnisonApp.updater.state.collect { if (visible) emit(UiJson.update(it)) } }
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

    /** Handles an invitation, `unison://join/CODE` or the https link of the server's invitation page; anything else is ignored. */
    fun onLink(uri: Uri?) {
        val own = uri?.scheme == "unison" && uri.host == "join"
        val web = uri?.scheme == "https" && uri.host == Uri.parse(Config.SERVER).host && uri.pathSegments.firstOrNull() == "join"
        if (uri == null || !own && !web) return
        val code = uri.lastPathSegment?.trim()?.uppercase()?.takeIf { INVITE_CODE.matches(it) } ?: return
        if (sink != null) emit(UiJson.invite(code)) else pendingInvite = code
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
            emit(UiJson.calm(UnisonApp.heat.calm.value))
            outputs.refresh()
            emit(UiJson.output(outputs.current.value))
            UnisonApp.updater.refreshPermission()
            UnisonApp.updater.check(force = false)
            emit(UiJson.update(UnisonApp.updater.state.value))
            UnisonApp.group.value?.resumeRoom()
            renewSuggestionsIfDue()
            if (autoDownload) DownloadWorker.enqueue(activity, waiting = true)
        }
        shown.value = value
        UnisonApp.setUiVisible(value)
    }

    /**
     * What the person called this phone in its settings ("Pixel 8"), or its model: the name offered in a room
     * until they choose another, so that following an invitation does not begin with a question.
     */
    private fun defaultName(): String {
        val named = runCatching { android.provider.Settings.Global.getString(activity.contentResolver, "device_name") }.getOrNull()
        return (named?.trim()?.takeIf { it.isNotEmpty() } ?: Build.MODEL).take(MAX_NAME_CHARS)
    }

    private val autoDownload get() = prefs.getBoolean(DownloadWorker.KEY_AUTO, false)

    /** On mobile data (or not knowing): songs are not fetched without asking. */
    private fun isMetered() = activity.getSystemService(ConnectivityManager::class.java)?.isActiveNetworkMetered != false

    /**
     * Brings the suggestions up to date when the person opens the app, at most twice an hour and not on a
     * metered connection: they are shown from what was kept, so there is no hurry and no reason to spend data.
     */
    private fun renewSuggestionsIfDue() {
        val now = SystemClock.elapsedRealtime()
        if (lastRenew != 0L && now - lastRenew < RENEW_EVERY_MS) return
        if (isMetered() || UnisonApp.heat.calm.value) return
        lastRenew = now
        scope.launch { UnisonApp.suggestions.renew(force = false) }
    }

    private var lastRenew = 0L

    fun dispose() {
        picture?.let {
            UnisonApp.group.value?.setVideoVisible(false)
            UnisonApp.group.value?.attachVideoSurface(null)
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
        emit(UiJson.update(UnisonApp.updater.state.value))
        emit(UiJson.calm(UnisonApp.heat.calm.value))
        emit(UiJson.output(outputs.current.value))
        observing?.cancel()
        observing = scope.launch {
            UnisonApp.group.collectLatest { group ->
                if (group == null) {
                    emit(UiJson.state(GroupController.View(), 0L, false, UnisonApp.videoMaxHeight))
                    return@collectLatest
                }
                coroutineScope {
                    launch {
                        // Drift and speed change every half second and are not part of the state; and
                        // nothing is built or sent while the screen is off, the UI catches up when it returns
                        combine(group.view.map(::structure).distinctUntilChanged(), shown) { view, on -> view.takeIf { on } }
                            .filterNotNull()
                            .collect { view ->
                                val state = UiJson.state(view, group.trimMs, group.videoMode, UnisonApp.videoMaxHeight)
                                if (state != lastState) {
                                    lastState = state
                                    emit(state)
                                }
                            }
                    }
                    launch { group.errors.collect { emit(UiJson.error(it.code, it.message)) } }
                    launch { group.notices.collect { emit(UiJson.notice(it)) } }
                    launch { group.sleep.state.collect { emit(UiJson.sleep(it)) } }
                    launch {
                        // No ticking at all while the screen is off
                        shown.collectLatest { on ->
                            while (on) {
                                emit(UiJson.position(group.view.value, group.playerInfo()))
                                delay(POSITION_TICK_MS)
                            }
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
                "name" to (prefs.getString("room_name", null) ?: defaultName()),
                "device" to Build.MODEL,
                "trimMs" to prefs.getLong("trim_ms", 0L),
                "videoHeight" to UnisonApp.videoMaxHeight,
                "server" to Config.SERVER,
                "autoplay" to prefs.getBoolean("autoplay", true),
            )
            "setupLink" -> return Config.setupLink()
            "smooth" -> {
                display.smooth(call.argument<Boolean>("on") == true)
                return null
            }
            "pickOutput" -> {
                outputs.pick()
                return null
            }
            "setLanguage" -> {
                UnisonApp.setLanguage(call.argument<String>("code") ?: "en")
                // The notes of an update come in the language that was just chosen
                if (visible) emit(UiJson.update(UnisonApp.updater.state.value))
                return null
            }
            "updateCheck" -> {
                UnisonApp.updater.check(force = true)
                return null
            }
            // Mobile data is asked about first: the file is some 30 MB
            "updateDownload" -> return if (UnisonApp.updater.download(call.argument<Boolean>("allowMetered") == true)) null else "metered"
            // "permission": Android has to be asked to let this app install first, and the UI says so
            "updateInstall" -> return if (UnisonApp.updater.install()) null else "permission"
            "updateAllowInstalls" -> {
                UnisonApp.updater.openInstallSettings()
                return null
            }
            "setAutoplay" -> {
                prefs.edit().putBoolean("autoplay", call.argument<Boolean>("on") == true).apply()
                return null
            }
            "forYou" -> return UnisonApp.suggestions.forYou().map { it.toMap() }
            "refreshSuggestions" -> {
                UnisonApp.suggestions.renew(force = true)
                return UnisonApp.suggestions.forYou().map { it.toMap() }
            }
            "seedLists" -> return UnisonApp.suggestions.seedLists().map { (seed, tracks) ->
                mapOf("seed" to seed, "tracks" to tracks.map { it.toMap() })
            }
            "musicTrending" -> return MusicJson.shelves(UnisonApp.musicFeed.trending(UnisonApp.language.value))
            "musicSearch" -> return UnisonApp.musicFeed.search(
                call.argument<String>("query").orEmpty(),
                call.argument<Boolean>("songs") == true,
            ).map(MusicJson::track)
            "musicNext" -> return MusicJson.next(UnisonApp.musicFeed.watchNext(call.argument<String>("videoId").orEmpty()))
            "musicRelated" -> return MusicJson.related(UnisonApp.musicFeed.related(call.argument<String>("videoId").orEmpty()))
            "musicArtist" -> return MusicJson.artist(UnisonApp.musicFeed.artist(call.argument<String>("id").orEmpty()))
            "lyrics" -> return MusicJson.lyrics(
                UnisonApp.musicFeed.lyrics(
                    call.argument<String>("videoId").orEmpty(),
                    call.argument<String>("title").orEmpty(),
                    call.argument<String>("artist").orEmpty(),
                    (call.argument<Number>("durMs") ?: 0).toLong() / 1000,
                ),
            )
            "suggest" -> return suggest(call.argument<String>("query").orEmpty())
            "searchPlaylists" -> return searchPlaylists(call.argument<String>("query").orEmpty())
            "search" -> return search(call.argument<String>("query").orEmpty(), call.argument<Boolean>("songsOnly") == true)
            "lookup" -> return lookup(call.argument<String>("text").orEmpty())
            "roomInfo" -> return roomInfo(call.argument<String>("code").orEmpty())
            "libraryLiked" -> return UnisonApp.library.liked().map { it.toMap() }
            "libraryRecent" -> return UnisonApp.library.recent().map { it.toMap() }
            "libraryLike" -> {
                val on = call.argument<Boolean>("on") == true
                UnisonApp.library.setLiked(trackRef(call.arguments()!!), on)
                if (on && autoDownload) DownloadWorker.enqueue(activity, waiting = true)
                return null
            }
            "downloads" -> return UnisonApp.library.downloads().map {
                it.track.toMap() + mapOf("state" to it.state, "bytes" to it.bytes)
            }
            "download" -> {
                // Songs the person asked for go on any network, but mobile data is asked about first
                if (isMetered() && call.argument<Boolean>("allowMetered") != true) return "metered"
                UnisonApp.library.requestDownloads(call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map(::trackRef))
                DownloadWorker.enqueue(activity, waiting = false)
                return "queued"
            }
            "downloadRemove" -> {
                val videoId = call.argument<String>("videoId").orEmpty()
                UnisonApp.library.removeDownload(videoId)
                withContext(Dispatchers.IO) { UnisonApp.caches.downloads.removeResource(videoId) }
                return null
            }
            "downloadClear" -> {
                UnisonApp.library.clearDownloads()
                withContext(Dispatchers.IO) { UnisonApp.caches.clearDownloads() }
                return null
            }
            "storage" -> return mapOf(
                "playBytes" to UnisonApp.caches.play.cacheSpace,
                "playLimitMb" to prefs.getInt("cache_limit_mb", UnisonApp.DEFAULT_CACHE_MB),
                "downloadBytes" to UnisonApp.caches.downloads.cacheSpace,
                "downloadCount" to UnisonApp.library.downloads().count { it.state == LibraryStore.DONE },
                "autoDownload" to autoDownload,
            )
            "clearPlayCache" -> {
                withContext(Dispatchers.IO) { UnisonApp.caches.clearPlay() }
                return null
            }
            "setCacheLimit" -> {
                // The size of the cache is fixed when it is opened, so this counts from the next start
                prefs.edit().putInt("cache_limit_mb", (call.argument<Number>("mb") ?: UnisonApp.DEFAULT_CACHE_MB).toInt()).apply()
                return null
            }
            "setAutoDownload" -> {
                val on = call.argument<Boolean>("on") == true
                prefs.edit().putBoolean(DownloadWorker.KEY_AUTO, on).apply()
                if (on) DownloadWorker.enqueue(activity, waiting = true) else DownloadWorker.cancelWaiting(activity)
                return null
            }
            "libraryClearHistory" -> {
                UnisonApp.library.clearHistory()
                return null
            }
            "playlists" -> return UnisonApp.library.playlists().map {
                mapOf("id" to it.id, "name" to it.name, "count" to it.count, "thumb" to it.thumb, "updatedAt" to it.updatedAt)
            }
            "playlistTracks" -> return UnisonApp.library.playlistTracks(playlistId(call)).map { it.toMap() }
            "playlistCreate" -> return UnisonApp.library.createPlaylist(
                call.argument<String>("name").orEmpty(),
                call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map(::trackRef),
            )
            "playlistRename" -> {
                UnisonApp.library.renamePlaylist(playlistId(call), call.argument<String>("name").orEmpty())
                return null
            }
            "playlistDelete" -> {
                UnisonApp.library.deletePlaylist(playlistId(call))
                return null
            }
            "playlistAdd" -> return UnisonApp.library.addToPlaylist(
                playlistId(call),
                call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map(::trackRef),
            )
            "playlistRemove" -> {
                UnisonApp.library.removeFromPlaylist(playlistId(call), call.argument<String>("videoId").orEmpty())
                return null
            }
            "playlistMove" -> {
                UnisonApp.library.movePlaylistItem(playlistId(call), call.argument<String>("videoId").orEmpty(), call.argument<Int>("to") ?: 0)
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
                return restored.toMap()
            }
            "share" -> {
                share(call.argument<String>("text").orEmpty())
                return null
            }
            "log" -> return EventLog.snapshot()
            "note" -> {
                EventLog.d("ui", call.argument<String>("line").orEmpty())
                return null
            }
        }

        val group = withTimeout(SERVICE_START_TIMEOUT_MS) { UnisonApp.group.first { it != null } }!!
        when (call.method) {
            "createRoom" -> {
                val code = createRoom()
                group.join(Config.SERVER, code, call.argument<String>("name").orEmpty(), create = true)
                return code
            }
            "join" -> group.join(
                Config.SERVER,
                call.argument<String>("code").orEmpty().trim().uppercase(),
                call.argument<String>("name").orEmpty(),
                create = false,
            )
            "leave" -> group.leave()
            "sleep" -> when (call.argument<String>("mode")) {
                "time" -> group.sleep.startIn(call.argument<Int>("minutes") ?: 0)
                "song" -> group.sleep.startAtSongEnd()
                else -> group.sleep.cancel()
            }
            "rename" -> group.rename(call.argument<String>("name").orEmpty().trim())
            "setTrim" -> {
                group.setTrim((call.argument<Number>("ms") ?: 0).toLong())
                // The trim is part of the state the UI shows, but the room itself did not change
                lastState = null
                emit(UiJson.state(group.view.value, group.trimMs, group.videoMode, UnisonApp.videoMaxHeight))
            }
            "videoMode" -> {
                group.setVideoMode(call.argument<Boolean>("on") == true)
                lastState = null
                emit(UiJson.state(group.view.value, group.trimMs, group.videoMode, UnisonApp.videoMaxHeight))
            }
            "videoVisible" -> group.setVideoVisible(call.argument<Boolean>("visible") == true)
            "videoSurface" -> return videoTexture(group)
            "videoQuality" -> {
                val height = (call.argument<Number>("height") ?: UnisonApp.DEFAULT_VIDEO_HEIGHT).toInt()
                UnisonApp.videoMaxHeight = height
                prefs.edit().putInt("video_height", height).apply()
                lastState = null
                emit(UiJson.state(group.view.value, group.trimMs, group.videoMode, UnisonApp.videoMaxHeight))
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
                    "roomSettings" -> {
                        requireRoom(group)
                        group.requestRoomSettings(call.argument<String>("guestControl").orEmpty())
                    }
                    "play" -> group.requestPlay { group.playLocally() }
                    "pause" -> group.requestPause()
                    "next" -> group.requestNext()
                    "prev" -> group.requestPrev()
                    "seek" -> group.requestSeek((call.argument<Number>("ms") ?: 0).toLong())
                    "jump" -> group.requestJump(call.argument<String>("id").orEmpty())
                    "clear" -> group.requestClearQueue()
                    "shuffle" -> group.requestShuffle()
                    "radio" -> group.requestRadio(call.argument<String>("videoId").orEmpty())
                    "repeat" -> group.requestRepeat(call.argument<String>("mode").orEmpty())
                    "addMany" -> group.requestAddMany(
                        call.argument<List<Map<String, Any?>>>("tracks").orEmpty().map(::trackRef),
                        call.argument<Boolean>("next") ?: false,
                    )
                    "swap" -> group.requestSwap(call.argument<String>("id").orEmpty(), trackRef(call.argument<Map<String, Any?>>("track")!!))
                    "remove" -> group.requestRemove(call.argument<String>("id").orEmpty())
                    "move" -> group.requestMove(call.argument<String>("id").orEmpty(), call.argument<Int>("to") ?: 0)
                    "add" -> group.requestAddMany(
                        listOf(trackRef(call.arguments()!!)),
                        call.argument<Boolean>("next") ?: false,
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
    private suspend fun roomInfo(code: String): Map<String, Any?>? = withContext(Dispatchers.IO) {
        val clean = code.trim().uppercase()
        if (!INVITE_CODE.matches(clean)) return@withContext null
        val request = Request.Builder().url("${Config.SERVER}/room/$clean/info")
            .apply { Config.authHeaders.forEach { (k, v) -> header(k, v) } }
            .build()
        http.newCall(request).execute().use {
            if (!it.isSuccessful) return@use null
            val json = JSONObject(it.body.string())
            mapOf(
                "exists" to json.optBoolean("exists"),
                "name" to if (json.isNull("name")) null else json.getString("name"),
                "members" to json.optInt("members"),
                "playing" to json.optBoolean("playing"),
                "title" to if (json.isNull("title")) null else json.getString("title"),
            )
        }
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

    private suspend fun search(query: String, songsOnly: Boolean): List<Map<String, Any?>> {
        if (query.isBlank()) return emptyList()
        return UnisonApp.resolver.search(query.trim(), SEARCH_LIMIT, songsOnly).map { it.toMap() }
    }

    /** Completions of a half-typed search; empty when YouTube cannot be reached, since they are only a help. */
    private suspend fun suggest(query: String): List<String> {
        if (query.isBlank()) return emptyList()
        return try {
            UnisonApp.resolver.suggest(query.trim()).take(SUGGESTION_LIMIT)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyList()
        }
    }

    private suspend fun searchPlaylists(query: String): List<Map<String, Any?>> {
        if (query.isBlank()) return emptyList()
        return UnisonApp.resolver.searchPlaylists(query.trim(), SEARCH_LIMIT).map {
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
        group.addPlayerListener(object : Player.Listener {
            override fun onVideoSizeChanged(size: androidx.media3.common.VideoSize) {
                if (size.width <= 0 || size.height <= 0) return
                producer.setSize(size.width, size.height)
                group.attachVideoSurface(producer.surface)
            }
        })
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

    private fun LibraryStore.Restored.toMap() = mapOf("liked" to liked, "playlists" to playlists, "listens" to listens)

    private fun playlistId(call: MethodCall): Long = call.argument<Number>("id")!!.toLong()

    /** A song as the UI sends it. */
    private fun trackRef(map: Map<String, Any?>) = TrackRef(
        videoId = map["videoId"] as String,
        title = map["title"] as String,
        artist = map["artist"] as? String ?: "",
        thumb = map["thumb"] as? String,
        durMs = (map["durMs"] as? Number)?.toLong() ?: 0L,
    )

    private fun TrackRef.toMap() = mapOf(
        "videoId" to videoId,
        "title" to title,
        "artist" to artist,
        "thumb" to thumb,
        "durMs" to durMs,
    )

    private fun LibraryStore.Entry.toMap() = mapOf(
        "videoId" to track.videoId,
        "title" to track.title,
        "artist" to track.artist,
        "thumb" to track.thumb,
        "durMs" to track.durMs,
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
        const val POSITION_TICK_MS = 1_000L

        /** The longest name the UI lets a person type. */
        const val MAX_NAME_CHARS = 24
        const val SERVICE_START_TIMEOUT_MS = 10_000L
        const val SEARCH_LIMIT = 20
        const val SUGGESTION_LIMIT = 6
        const val RENEW_EVERY_MS = 30 * 60_000L
        const val PLAYLIST_LIMIT = 50
        const val VIDEO_DEFAULT_WIDTH = 1280
        const val VIDEO_DEFAULT_HEIGHT = 720
        private val INVITE_CODE = Regex("[A-Z0-9]{6}")
    }
}
