package app.sapoche

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.view.Surface
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import app.sapoche.sync.LocalMusic
import app.sapoche.sync.NetworkHealth
import app.sapoche.sync.ChatCipher
import app.sapoche.sync.ChatMessage
import app.sapoche.sync.ChatNotice
import app.sapoche.sync.ChatNotices
import app.sapoche.sync.ChatQuote
import app.sapoche.sync.ChatReceipt
import app.sapoche.sync.ClockSync
import app.sapoche.sync.Connection
import app.sapoche.sync.GroupSession
import app.sapoche.sync.ListenSource
import app.sapoche.sync.ListenSources
import app.sapoche.sync.LoadFailure
import app.sapoche.sync.LocalSession
import app.sapoche.sync.QueueItem
import app.sapoche.sync.Protocol
import app.sapoche.sync.QueueFile
import app.sapoche.sync.Queues
import app.sapoche.sync.RoomClient
import app.sapoche.sync.RoomState
import app.sapoche.sync.SavedQueue
import app.sapoche.sync.Sleep
import app.sapoche.sync.SleepTimer
import app.sapoche.sync.TasteSeed
import app.sapoche.sync.TrackRef
import app.sapoche.sync.ServerMessage
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Lives in the playback service so the room connection survives the activity. While joined, the
 * room decides what plays; while not joined, the player plays the personal queue, like any music player.
 */
class GroupController(
    private val context: Context,
    private val exo: ExoPlayer,
    private val prefs: SharedPreferences,
    private val queueFile: QueueFile,
    /** Up to [Int] songs to carry on with after the songs [List] (video ids) together, leaving out the ids given. */
    private val moreLike: suspend (List<String>, Set<String>, Int) -> List<TrackRef> = { _, _, _ -> emptyList() },
    /** The songs this person offers a room's autoplay to start from: a few they love, never songs of files. */
    private val tasteOffer: suspend () -> List<TrackRef> = { emptyList() },
) {
    // Main thread: ExoPlayer must be used there, and the session only does light work
    private var scope = newScope()
    private val port = ExoPlayerPort(exo)
    private val clock = ClockSync()

    /** Lives as long as this controller; [scope] is replaced each time a room is left. */
    private val ownScope = newScope()

    /** Saving the queue is disk work, so it is done off the main thread, in order. */
    private val writer = Executors.newSingleThreadExecutor()

    /** The queue that plays outside a room; it comes back after a restart, paused. */
    /** What is known about the network, whether listening in a room or alone: it decides the quality songs are fetched in. */
    private val health = NetworkHealth().also { it.onChange = { weak -> SapocheApp.weakNetwork = weak; if (weak) EventLog.w("net", "weak network: the room may run ahead") else EventLog.k("net", "network is good again") } }

    val local = LocalSession(
        ownScope,
        port,
        queueFile.read(),
        persist = { saved -> writer.execute { runCatching { queueFile.write(saved) } } },
        problem = { problem -> _errors.tryEmit(ServerMessage.Error(problem.kind.code, problem.title)) },
        log = { EventLog.d("local", it) },
        onQueueEnd = ::autoplay,
        health = health,
    )

    /** Which songs of the queue autoplay or a shelf put there, so a listen can say where it came from. */
    private val sources = ListenSources()

    /** Where the song [videoId], now playing, came from; see [ListenSource]. */
    fun listenSource(videoId: String): String {
        val s = session ?: return sources.of(videoId)
        val state = s.snapshot.value.state ?: return sources.of(videoId)
        val item = state.queue.getOrNull(state.index)?.takeIf { it.videoId == videoId } ?: state.queue.firstOrNull { it.videoId == videoId }
        return sources.of(videoId, item, s.snapshot.value.you)
    }

    /** The song that was just left was skipped by another member of the room, not by this device. */
    fun leftByOther(): Boolean = session?.let { !it.isSolo && it.changedByOther } ?: false

    private var autoplayJob: Job? = null
    private var radioJob: Job? = null

    /** Keeps the phone awake between the last song and the next, when ExoPlayer holds nothing (see [AwakeHold]). */
    private val awake = AwakeHold(context, ownScope)

    /** The job that looks for songs for the room, and the epoch of the question it answers; see [fillRoom]. */
    private var fillJob: Job? = null
    private var fillEpoch: Long? = null

    /** Songs found for the room that could not be sent because the connection was down; sent when it is back and the room is still waiting for them. */
    private var owedFill: OwedFill? = null

    private class OwedFill(val epoch: Long, val songs: List<TrackRef>, val title: String)

    /** Songs of different loudness are played at one level, unless the person turned that off. */
    private val balance = VolumeBalance(
        exo, SapocheApp.loudness, ownScope,
        on = { prefs.getBoolean(KEY_NORMALIZE, true) },
        crossfade = { prefs.getInt(KEY_CROSSFADE, 0) },
        pictureShown = { port.pictureShown },
    )

    /** The screen turns the evening out on or off by writing the choice; the song that plays follows at once. (Kept in a field: preferences hold their listeners weakly.) */
    private val normalizeListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == KEY_NORMALIZE || key == KEY_CROSSFADE) balance.changed()
    }.also { prefs.registerOnSharedPreferenceChangeListener(it) }

    /** Stops this device after a while, or when the song is over; the fade is a share of the song's own volume. */
    val sleep = SleepTimer(
        ownScope,
        wallClock = System::currentTimeMillis,
        stop = ::stopForSleep,
        fade = balance::fade,
        pauseAtSongEnd = { exo.setPauseAtEndOfMediaItems(it) },
    )

    private var client: RoomClient? = null
    private var session: GroupSession? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /** What the UI shows: the room as last announced, plus the connection to it, and the personal queue for outside a room. */
    data class View(
        val roomCode: String? = null,
        val connection: Connection? = null,
        val snapshot: GroupSession.Snapshot = GroupSession.Snapshot(),
        val local: LocalSession.Snapshot = LocalSession.Snapshot(),
        /** This device has the secret of the room's end-to-end encrypted chat. */
        val sealedKey: Boolean = false,
    )

    private val _view = MutableStateFlow(View(local = local.snapshot.value))
    val view: StateFlow<View> = _view.asStateFlow()

    /** Errors the server reports to this device, e.g. a track nobody could play. */
    private val _errors = MutableSharedFlow<ServerMessage.Error>(extraBufferCapacity = 8)
    val errors: SharedFlow<ServerMessage.Error> = _errors.asSharedFlow()

    /** Something another member did that moved this device, with their name already looked up. */
    data class Notice(val kind: String, val by: String, val title: String? = null)

    private val _notices = MutableSharedFlow<Notice>(extraBufferCapacity = 8)
    val notices: SharedFlow<Notice> = _notices.asSharedFlow()

    /** Callers of [mediaTickets] waiting for the room's answer, by the id of their request. */
    private val ticketWaiters = java.util.concurrent.ConcurrentHashMap<String, CompletableDeferred<ServerMessage>>()

    /** A member's picture, as base64; [data] is null when they have none (any more). */
    data class Avatar(val id: String, val data: String?)

    private val _avatars = MutableSharedFlow<Avatar>(extraBufferCapacity = 64)
    val avatars: SharedFlow<Avatar> = _avatars.asSharedFlow()

    /** The latest picture of each member, for a screen that comes back after pictures arrived. */
    private val pictures = java.util.concurrent.ConcurrentHashMap<String, String>()

    fun picturesSeen(): List<Avatar> = pictures.map { Avatar(it.key, it.value) }

    /**
     * Chat messages of room [room]: all it keeps when [replace], else new ones to add or ones that changed. [receipts] is
     * what each member has got of the chat when that changed (or came with everything), else null. [older]: a page of
     * messages from before the ones shown, asked for with [loadOlderChat]. [more]: the room keeps messages from before the
     * oldest shown (null when this says nothing about it).
     */
    data class Chat(
        val room: String,
        val messages: List<ChatMessage>,
        val replace: Boolean,
        val receipts: Map<String, ChatReceipt>? = null,
        val older: Boolean = false,
        val more: Boolean? = null,
    )

    private val _chat = MutableSharedFlow<Chat>(extraBufferCapacity = 64)
    val chat: SharedFlow<Chat> = _chat.asSharedFlow()

    /** What the person is to be told of the chat; whether it is shown depends on whether they are looking at the app. */
    private val _chatNotices = MutableSharedFlow<ChatNotice>(extraBufferCapacity = 16)
    val chatNotices: SharedFlow<ChatNotice> = _chatNotices.asSharedFlow()

    /** The room's chat as last heard; null until the room sent its history (a server older than protocol 10 never does). */
    @Volatile
    private var chatLog: List<ChatMessage>? = null

    /** What each member has got of the chat, as the room last said. */
    @Volatile
    private var receiptsLog: Map<String, ChatReceipt> = emptyMap()

    /** The last message this device told the room it has, so that it says so once for each. */
    @Volatile
    private var deliveredUpTo = 0L

    /** Whether the room kept messages from before [chatLog], as it said last. */
    @Volatile
    private var chatMore = false

    /** The whole chat, for a screen that comes back after messages arrived. */
    fun chatSeen(): Chat? {
        val code = roomCode ?: return null
        return chatLog?.let { Chat(code, open(code, it), replace = true, receipts = receiptsLog, more = chatMore) }
    }

    /** [messages] as the room sent them, with the words of sealed ones read when this device has the room's secret. */
    private fun open(room: String, messages: List<ChatMessage>): List<ChatMessage> = messages.map { open(room, it) }

    private fun open(room: String, message: ChatMessage): ChatMessage {
        if (message.ct == null) return message
        val secret = SapocheApp.roomKeys.get(room)
        return secret?.let { ChatCipher.openMessage(it, room, message) } ?: message.copy(text = "", re = null, locked = true)
    }

    /**
     * Another device's secret for room [code] came (from an invitation link, or this device made it): kept, and the chat
     * is shown again, now that it can be read.
     */
    fun roomSecretChanged(code: String) {
        if (code.uppercase() != roomCode) return
        publish()
        chatSeen()?.let { _chat.tryEmit(it) }
    }

    /**
     * Turns on end-to-end encryption in the room this device owns: a new secret is made and kept here, and the room is
     * told, which deletes the chat so far. The secret is then to be given to the others, with [roomSecret]. False when
     * this device is not in a room it owns, or the room is sealed already.
     */
    fun enableEncryption(): Boolean {
        val code = roomCode ?: return false
        val snapshot = session?.snapshot?.value ?: return false
        if (snapshot.state?.enc == true || snapshot.state?.ownerId != snapshot.you) return false
        SapocheApp.roomKeys.put(code, ChatCipher.newSecret())
        publish()
        return send(Protocol.roomEncrypt())
    }

    /** The secret of the room this device is in, as written in an invitation link; null when it has none. */
    fun roomSecret(): String? {
        val code = roomCode ?: return null
        return SapocheApp.roomKeys.get(code)?.let(ChatCipher::encodeSecret)
    }

    private fun openBackground(room: String, envelope: String): String? {
        val secret = SapocheApp.roomKeys.get(room) ?: return null
        return ChatCipher.openBackground(secret, room, envelope)?.let { Base64.encodeToString(it, Base64.NO_WRAP) }
    }

    /** Asks the room for the messages older than number [before]; false when there is no connection to ask on. */
    fun loadOlderChat(before: Long): Boolean = client?.send(Protocol.chatBefore(before)) ?: false

    /** Member [by] reacted with [e], [n] taps of it. */
    data class Reaction(val by: String, val e: String, val n: Int)

    private val _reactions = MutableSharedFlow<Reaction>(extraBufferCapacity = 16)
    val reactions: SharedFlow<Reaction> = _reactions.asSharedFlow()

    /** Sends a chat message, as an answer to message number [reply] when it has one; false when there is no connection to send it on. */
    fun sendChat(text: String, cid: String, reply: Long? = null, quote: ChatQuote? = null, extra: JsonObject? = null): Boolean {
        val sender = client ?: return false
        val code = roomCode ?: return false
        val snapshot = session?.snapshot?.value
        if (snapshot?.state?.enc != true) return sender.send(Protocol.chat(text, cid, reply, extra))
        // A sealed room: the words go sealed, with what they answer and what they carry inside; without the secret there is nothing to send
        val secret = SapocheApp.roomKeys.get(code) ?: return false
        val you = snapshot.you ?: return false
        val (ct, pv) = ChatCipher.sealMessage(secret, code, you, text, quote, extra)
        return sender.send(Protocol.chatSealed(ct, pv, cid, reply))
    }

    /** Gives chat message [id] this device's reaction [e] (a name of the room's reactions or an emoji); null takes it away. */
    fun reactToChat(id: Long, e: String?) {
        client?.send(Protocol.chatReact(id, e))
    }

    /** The chat is on a screen, and its messages up to number [upTo] have been looked at. */
    fun readChat(upTo: Long) {
        client?.send(Protocol.chatReceipt(read = upTo))
    }

    fun react(e: String, n: Int) {
        client?.send(Protocol.react(e, n))
    }

    /** The picture this device shows the room as its own, as base64 of a small JPEG; null for none. Kept across restarts. */
    fun setAvatar(data: String?) {
        prefs.edit().apply { if (data == null) remove(KEY_AVATAR) else putString(KEY_AVATAR, data) }.apply()
        client?.setAvatar(data)
    }

    var roomCode: String? = null
        private set

    val isActive: Boolean get() = client != null

    /** The connection was let go of after a long idle spell, see [suspendRoom]. */
    private var suspended = false

    /** Commands given while [suspended], sent once the connection is back. */
    private val pending = mutableListOf<String>()

    /** Songs are played with their picture; this device's choice, remembered across runs. */
    var videoMode: Boolean = prefs.getBoolean(KEY_VIDEO, false)
        private set

    init {
        port.setVideoMode(videoMode)
        local.attach()
        // After the personal queue's own listener: when the last song ends it must see the timer still set
        exo.addListener(object : Player.Listener {
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (reason == Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM) sleep.songEnded()
                // Another app took the sound for good, or the headphones went: in a room this device stays quiet
                // until its person presses play, whatever the room does meanwhile
                if (!playWhenReady && (reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS ||
                        reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY)
                ) {
                    session?.hold()
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED) sleep.songEnded()
            }

            // From here ExoPlayer holds the CPU and the Wi-Fi itself
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying) awake.release("the music plays")
            }
        })
        ownScope.launch { local.snapshot.collect { publish() } }
    }

    /**
     * The personal queue ran out. Unless the person turned it off, it carries on with songs like the last
     * one, so the music does not just stop. Nothing happens without a network, in a room, or when they
     * asked for something else in the meantime.
     */
    private fun autoplay(last: QueueItem, retryOfDebt: Boolean = false) {
        forgetOwedAutoplay("autoplay starts")
        if (!autoplayOn || session != null || autoplayJob?.isActive == true || sleep.state.value == Sleep.SongEnd) return
        // A song from a file on this phone has no radio: the last song from YouTube in the queue stands in for it
        val like = if (!LocalMusic.isLocal(last.videoId)) last else local.snapshot.value.queue.lastOrNull { !LocalMusic.isLocal(it.videoId) } ?: return
        autoplayJob = ownScope.launch {
            // Still wanted: the person did not turn it off, join a room or ask for something else while the songs are looked for
            val wanted = { autoplayOn && session == null && local.snapshot.value.finished && sleep.state.value != Sleep.SongEnd }
            var added = false
            try {
                val more = Queues.retrying(
                    stillWanted = wanted,
                    missed = { n, e -> EventLog.d("local", "autoplay try #$n found nothing${e?.let { ": ${it.javaClass.simpleName}: ${it.message}" } ?: ""}") },
                ) {
                    awake.hold("autoplay")
                    moreLike(listOf(like.videoId), local.snapshot.value.queue.map { it.videoId }.toSet(), AUTOPLAY_COUNT)
                }
                if (more.isEmpty() || !wanted()) {
                    // Nothing found though still wanted: one more round when the network comes back, if that is soon
                    if (more.isEmpty() && wanted() && !retryOfDebt) oweAutoplay(like)
                    return@launch
                }
                EventLog.d("local", "autoplay adds ${more.size} songs like '${like.title}'")
                // Carrying on only adds: what has been played makes room when the new songs would not fit
                local.dropPlayed(local.snapshot.value.queue.size + more.size - LocalSession.MAX_QUEUE)
                sources.mark(more.map { it.videoId }, ListenSource.AUTO)
                local.add(more, next = false, queued = false, auto = true)
                added = true // the song still has to be fetched: the hold goes when it plays
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                EventLog.d("local", "autoplay found nothing: ${e.javaClass.simpleName}: ${e.message}")
            } finally {
                if (!added) awake.release("autoplay gave up")
            }
        }
    }

    /** The song autoplay looked for songs like in vain while still wanted, and when it gave up; see [oweAutoplay]. */
    private var owedAutoplay: Pair<QueueItem, Long>? = null
    private var owedNetwork: ConnectivityManager.NetworkCallback? = null
    private var owedJob: Job? = null

    /**
     * All the tries of [autoplay] found nothing and the music is at a stop. When the network changes or comes back within
     * [AUTOPLAY_OWED_MS], one more round is made; later the music starting by itself would only be a surprise.
     */
    private fun oweAutoplay(like: QueueItem) {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        owedAutoplay = like to SystemClock.elapsedRealtime()
        var current: Network? = null
        var armed = false // the network that was there when the debt began is not news
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (current != null && current != network) armed = true
                current = network
                if (armed) Handler(Looper.getMainLooper()).post { owedNetworkBack() }
            }

            override fun onLost(network: Network) {
                if (current == network) {
                    current = null
                    armed = true
                }
            }
        }
        try {
            cm.registerDefaultNetworkCallback(callback)
            owedNetwork = callback
        } catch (e: RuntimeException) {
            owedAutoplay = null
            EventLog.d("local", "cannot watch the network for autoplay: ${e.message}")
            return
        }
        owedJob?.cancel()
        owedJob = ownScope.launch {
            delay(AUTOPLAY_OWED_MS)
            forgetOwedAutoplay("it is too late now")
        }
        EventLog.d("local", "autoplay owes one more try when the network is back, for ${AUTOPLAY_OWED_MS / 60_000} minutes")
    }

    private fun owedNetworkBack() {
        val (like, _) = owedAutoplay ?: return
        forgetOwedAutoplay("the network is back")
        autoplay(like, retryOfDebt = true)
    }

    private fun forgetOwedAutoplay(why: String) {
        owedJob?.cancel()
        owedJob = null
        owedNetwork?.let { callback -> runCatching { context.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(callback) } }
        owedNetwork = null
        if (owedAutoplay != null) EventLog.d("local", "autoplay owes nothing any more: $why")
        owedAutoplay = null
    }

    /**
     * The room's queue ran out and the server asked this device for songs like the last one, as [autoplay] does for the
     * personal queue. The search is tried again when it finds nothing, and the same question twice (the server puts it
     * again when a device comes in) does not start a second search. Nothing is sent when the room has moved on by the
     * time the songs arrive; songs found while the connection was down are sent when it is back (see [deliverOwedFill]).
     */
    private fun fillRoom(ask: ServerMessage.AutoplayFill) {
        if (fillJob?.isActive == true) {
            if (fillEpoch == ask.epoch) {
                EventLog.d("sync", "autoplay is asked again for epoch ${ask.epoch}, it is already looking")
                return
            }
            fillJob?.cancel()
        }
        owedFill?.takeIf { it.epoch == ask.epoch }?.let {
            if (deliverOwedFill(session?.snapshot?.value?.state)) return
        }
        owedFill = null
        fillEpoch = ask.epoch
        fillJob = scope.launch {
            val wanted = { roomWaitsFor(ask.epoch, session?.snapshot?.value?.state) }
            var answered = false
            try {
                // The songs of the queue, and a song of each member who offered some, going round with each time the room runs out
                val seeds = Queues.blend(Queues.seeds(queue(), ask.videoId), openOffers(ask.tastes), ask.epoch)
                val more = Queues.retrying(
                    stillWanted = wanted,
                    missed = { n, e -> EventLog.d("sync", "autoplay try #$n found nothing for the room${e?.let { ": ${it.javaClass.simpleName}: ${it.message}" } ?: ""}") },
                ) {
                    awake.hold("autoplay for the room")
                    moreLike(seeds, queue().map { it.videoId }.toSet(), AUTOPLAY_COUNT)
                }
                if (more.isEmpty()) {
                    EventLog.d("sync", if (wanted()) "autoplay found nothing for the room, the room asks another device" else "autoplay found nothing and the room had moved on")
                    return@launch
                }
                if (!wanted()) {
                    EventLog.d("sync", "autoplay found ${more.size} songs but the room had moved on")
                    return@launch
                }
                EventLog.d("sync", "autoplay found ${more.size} songs like '${ask.title}' and ${seeds.size - 1} more for the room")
                if (!sendFill(more)) {
                    owedFill = OwedFill(ask.epoch, more, ask.title)
                    EventLog.d("sync", "fill owed: the room cannot be reached, the songs are kept until it can")
                }
                answered = true // the room starts the song and sends it to prepare: the hold goes when it plays
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                EventLog.d("sync", "autoplay found nothing for the room: ${e.javaClass.simpleName}: ${e.message}")
            } finally {
                if (!answered) awake.release("autoplay for the room gave up")
            }
        }
    }

    /** Marked as autoplay's, so the room keeps them apart from the songs its members chose. Whether it could be sent. */
    private fun sendFill(songs: List<TrackRef>): Boolean = send(Protocol.queueAddMany(songs, auto = true))

    /** The room is idle at [epoch] and still asks for songs: the answer to its question can still be used. */
    private fun roomWaitsFor(epoch: Long, state: RoomState?): Boolean =
        state != null && state.epoch == epoch && state.phase == "idle" && state.autoplay != false

    /** A [state] of the room came: songs [owedFill] kept are sent if the room still waits for them. Whether anything was sent. */
    private fun deliverOwedFill(state: RoomState?): Boolean {
        val owed = owedFill ?: return false
        owedFill = null // sent or not, an answer is given once
        if (!roomWaitsFor(owed.epoch, state)) {
            EventLog.d("sync", "fill owed: the room had moved on, the songs are dropped")
            return false
        }
        val sent = sendFill(owed.songs)
        EventLog.d("sync", "fill owed: ${owed.songs.size} songs like '${owed.title}' ${if (sent) "sent now" else "could not be sent"}")
        return sent
    }

    /** Whether this device offers the songs it loves to a room's autoplay (on unless the person turned it off). */
    var shareTasteOn: Boolean
        get() = prefs.getBoolean(KEY_SHARE_TASTE, true)
        set(value) {
            prefs.edit().putBoolean(KEY_SHARE_TASTE, value).apply()
            shareTaste()
        }

    /** The message last sent about this device's songs on this connection, so the same one is not sent again at every state. */
    private var sentTaste: String? = null
    private var tasteJob: Job? = null

    /** What this person loves changed (a song was heard, a mark put on the taste): tells the room soon, if it differs. */
    fun tasteChanged() {
        if (session == null) return
        tasteJob?.cancel()
        tasteJob = scope.launch {
            delay(TASTE_DELAY_MS)
            shareTaste()
        }
    }

    /**
     * Hands the room the songs this device offers autoplay, or takes them back when the person does not want to share,
     * once per connection and again when they change. A room whose chat is sealed is given them sealed, and without its
     * secret nothing can be offered. The server must know protocol 19.
     */
    private fun shareTaste() {
        val s = session ?: return
        scope.launch {
            // Read once the session has taken in the state that came with this
            val state = s.snapshot.value.state ?: return@launch
            val code = roomCode ?: return@launch
            val you = s.snapshot.value.you ?: return@launch
            val sealed = state.enc
            val offer = if (shareTasteOn) {
                try {
                    tasteOffer().map { TasteSeed(it.videoId, it.title.take(TASTE_TEXT), it.artist.take(TASTE_TEXT)) }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    return@launch
                }
            } else {
                emptyList()
            }
            val message = when {
                offer.isEmpty() -> if (sealed) Protocol.tasteSetSealed(null) else Protocol.tasteSet(null)
                !sealed -> Protocol.tasteSet(offer)
                else -> {
                    val secret = SapocheApp.roomKeys.get(code)
                    if (secret == null) Protocol.tasteSetSealed(null) else Protocol.tasteSetSealed(ChatCipher.sealTaste(secret, code, you, offer))
                }
            }
            if (message == sentTaste || session !== s) return@launch
            if (send(message)) sentTaste = message
        }
    }

    /** The video ids each member offered in [tastes], opened with the room's secret when the chat is sealed; a member whose offer cannot be read is left out. */
    private fun openOffers(tastes: List<ServerMessage.MemberTaste>): List<List<String>> {
        val code = roomCode ?: return emptyList()
        val secret = if (session?.snapshot?.value?.state?.enc == true) SapocheApp.roomKeys.get(code) else null
        return tastes.map { member ->
            val seeds = member.seeds ?: member.s?.let { sealed -> secret?.let { ChatCipher.openTaste(it, code, member.by, sealed) } }
            seeds.orEmpty().map { it.v }
        }
    }

    /**
     * A song was started on its own, from a search or a shelf. Like YouTube Music, the queue fills with songs like
     * it, so skipping works at once and the music carries on. Nothing is added when autoplay is off, in a room, or
     * when the person has changed the queue by the time the songs arrive.
     */
    fun requestRadio(videoId: String) {
        radioJob?.cancel()
        if (!autoplayOn || session != null) return
        radioJob = ownScope.launch {
            try {
                // The song that was tapped comes first: on a slow network the two would share it
                local.snapshot.first { !it.loading }
                val more = moreLike(listOf(videoId), setOf(videoId), RADIO_COUNT)
                val snap = local.snapshot.value
                val contextOnly = snap.queue.filterNot { it.id in snap.queued }
                if (more.isEmpty() || session != null || contextOnly.singleOrNull()?.videoId != videoId) return@launch
                EventLog.d("local", "radio adds ${more.size} songs like $videoId")
                sources.mark(more.map { it.videoId }, ListenSource.AUTO)
                local.add(more, next = false, queued = false)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                EventLog.d("local", "no radio for $videoId: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    /** The sleep timer ran out. In a room only this device stops: it carries on alone, paused, and the room plays on. */
    private fun stopForSleep() {
        val s = session
        if (s == null) {
            local.pause()
            return
        }
        if (!s.isSolo) s.goSolo()
        s.soloPause()
    }

    /** Whether the music carries on by itself when the queue runs out. */
    var autoplayOn: Boolean
        get() = prefs.getBoolean(KEY_AUTOPLAY, true)
        set(value) {
            prefs.edit().putBoolean(KEY_AUTOPLAY, value).apply()
            // Turned on when the queue had already run out: it carries on now, not at the end of the next queue
            if (value && session == null && local.snapshot.value.finished) local.snapshot.value.queue.lastOrNull()?.let { autoplay(it) }
        }

    fun setVideoMode(on: Boolean) {
        videoMode = on
        prefs.edit().putBoolean(KEY_VIDEO, on).apply()
        port.setVideoMode(on)
        EventLog.d("video", "picture ${if (on) "on" else "off"}")
    }

    /** The picture is on screen; when it is not, it is neither downloaded nor decoded. */
    fun setVideoVisible(visible: Boolean) = port.setVideoVisible(visible)

    /** How fast the personal queue plays, 1 being normal. Not kept across runs, and 1 in a room, where the speed keeps the phones in step. */
    var playbackSpeed: Float = 1f
        private set

    /** Plays the personal queue faster or slower; in a room the speed is the drift control's, and this does nothing. */
    fun setPlaybackSpeed(speed: Float) {
        if (session != null) return
        playbackSpeed = speed.coerceIn(MIN_SPEED, MAX_SPEED)
        port.setSpeed(playbackSpeed)
        EventLog.d("local", "speed $playbackSpeed")
    }

    /** The surface the player draws the picture on now; see [attachVideoSurface]. */
    private var videoSurface: Surface? = null

    /**
     * Where the player draws the picture, or null to let go of the screen. Only a change is passed on: the player
     * reports the size of the picture again each time it is given a surface, even the one it has, and whoever
     * listens for the size gives the surface again, so the same surface set twice keeps two threads busy for as
     * long as the picture is shown (a phone that gets hot, and an app that stops answering).
     */
    fun attachVideoSurface(surface: Surface?) {
        if (surface === videoSurface) return
        videoSurface = surface
        if (surface == null) exo.clearVideoSurface() else exo.setVideoSurface(surface)
    }

    /** Per-device latency correction in ms, see [GroupSession.trimMs]. */
    var trimMs: Long = prefs.getLong(KEY_TRIM_MS, 0L)
        private set

    /** [create] says whether the code was just made (true) or given to this device (false): a mistyped code must not open a room. */
    fun join(baseUrl: String, code: String, name: String, create: Boolean) {
        stopFollowing()
        local.detach()
        // The room plays at its own pace
        if (playbackSpeed != 1f) {
            playbackSpeed = 1f
            port.setSpeed(1f)
        }
        val id = deviceId()
        val now = { SystemClock.elapsedRealtime() }
        val log = { message: String -> EventLog.d("sync", message) }

        val newSession = GroupSession(scope, port, clock, now, { text -> client?.send(text) }, log, health = health)
        newSession.trimMs = trimMs
        newSession.startBiasMs = prefs.getLong(KEY_START_BIAS_MS, 0L)
        newSession.onStartBiasLearned = { prefs.edit().putLong(KEY_START_BIAS_MS, it).apply() }
        val newClient = RoomClient(baseUrl, code, id, name, scope, clock, now, log, Config.authHeaders, create, appVersion = BuildConfig.VERSION_NAME)
        newClient.onMessage = {
            if (it is ServerMessage.Error) _errors.tryEmit(it)
            if (it is ServerMessage.AutoplayFill) fillRoom(it)
            if (it is ServerMessage.State) {
                if (owedFill != null && fillJob?.isActive != true) deliverOwedFill(it.state)
                // The room ran out of songs and carries on by itself: every device needs to be awake to load what it adds.
                // This runs on OkHttp's thread; the player and the wake locks belong to the main one, so it is asked there,
                // in the order of the messages (before the session has the state, as it was)
                val state = it.state
                scope.launch {
                    if (state.phase == "idle" && state.autoplay == true && state.queue.isNotEmpty() && !awake.held &&
                        !exo.isPlaying && sleep.state.value != Sleep.SongEnd
                    ) {
                        awake.hold("the room ran out of songs")
                    }
                }
            }
            if (it is ServerMessage.MediaTicket) ticketWaiters[it.id]?.complete(it)
            // An error of the pictures is the answer to the one request that waits for it
            if (it is ServerMessage.Error && it.code.startsWith("media_")) ticketWaiters.values.firstOrNull()?.complete(it)
            onChat(code.uppercase(), it)
            newSession.onMessage(it)
            // The song loads paused: the hold is taken after the session has stopped the player
            if (it is ServerMessage.Prepare) scope.launch { if (!exo.isPlaying) awake.hold("a song of the room to load") }
            // After the session has the state: the offer depends on whether the room's chat is sealed
            if (it is ServerMessage.State && it.protocol >= TASTE_PROTOCOL) shareTaste()
        }
        newClient.onAvatar = { memberId, _, received, sealed ->
            // The picture behind a sealed chat is opened here, so the screen gets a JPEG as ever; without the secret there is none
            val data = if (!sealed || received == null) received else openBackground(code, received)
            if (data == null) pictures.remove(memberId) else pictures[memberId] = data
            _avatars.tryEmit(Avatar(memberId, data))
        }
        newClient.setAvatar(prefs.getString(KEY_AVATAR, null))
        newClient.onConnected = {
            sentTaste = null
            newSession.onReconnected()
            scope.launch { flushPending(newClient) }
        }

        session = newSession
        client = newClient
        suspended = false
        pending.clear()
        roomCode = code.uppercase()
        publish()
        scope.launch { newSession.snapshot.collect { publish() } }
        // Listening alone is remembered, so that a restart brings this device back to it instead of into the room's music
        scope.launch {
            newSession.snapshot.map { it.solo to it.soloItemId }.distinctUntilChanged().collect { (solo, itemId) ->
                prefs.edit().putBoolean(KEY_ROOM_SOLO, solo).putString(KEY_ROOM_SOLO_ITEM, itemId).apply()
            }
        }
        scope.launch {
            while (true) {
                prefs.edit().putLong(KEY_LAST_ACTIVE, System.currentTimeMillis()).apply()
                delay(ACTIVE_STAMP_MS)
            }
        }
        scope.launch {
            newSession.events.collect { event ->
                val members = newSession.snapshot.value.members
                val name = { id: String -> members.firstOrNull { it.id == id }?.name.orEmpty() }
                when (event) {
                    is GroupSession.RoomEvent.Paused -> _notices.tryEmit(Notice("paused", name(event.byId)))
                    is GroupSession.RoomEvent.Waiting -> _notices.tryEmit(Notice("waiting", name(event.byId)))
                    is GroupSession.RoomEvent.Skipped -> _notices.tryEmit(Notice("skipped", name(event.byId), event.title))
                    // Told as the personal queue tells it: the person may be the only one not hearing the song
                    is GroupSession.RoomEvent.LoadFailed -> _errors.tryEmit(ServerMessage.Error(loadFailureCode(event.reason), event.title))
                }
            }
        }
        scope.launch {
            newClient.connection.collect { connection ->
                publish()
                // Turned away for good (the room is full, gone, or the owner removed this device): back to the personal queue.
                // Posted, because leaving cancels the scope this is running in.
                if (connection == Connection.REFUSED) Handler(Looper.getMainLooper()).post { leave() }
            }
        }
        prefs.edit().putString(KEY_ROOM_CODE, roomCode).putString(KEY_ROOM_NAME, name).apply()
        EventLog.d("sync", "joining room $roomCode as '$name' ($id)")
        newClient.start()
        watchNetwork(newClient)
    }

    /** Reconnect at once when the network comes back or changes, instead of waiting out the backoff. */
    private fun watchNetwork(target: RoomClient) {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        var current: Network? = null
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val changed = current != null && current != network
                current = network
                if (changed || target.connection.value != Connection.CONNECTED) {
                    EventLog.d("sync", "network available, reconnecting now")
                    target.reconnectNow()
                }
            }

            override fun onLost(network: Network) {
                if (current == network) current = null
            }
        }
        try {
            cm.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (e: RuntimeException) {
            EventLog.d("sync", "cannot watch the network: ${e.message}")
        }
    }

    /** Leave on the user's request: the room is forgotten and will not be rejoined automatically. */
    fun leave() {
        prefs.edit().remove(KEY_ROOM_CODE).remove(KEY_ROOM_SOLO).remove(KEY_ROOM_SOLO_ITEM).apply()
        stopFollowing()
    }

    /**
     * Called when the service starts. A room is only rejoined when the system killed the process while this
     * device was in it a moment ago, and listening alone comes back as such, paused. Opening the app any other
     * time starts outside a room, on the personal queue.
     */
    fun recoverRoom() {
        val code = prefs.getString(KEY_ROOM_CODE, null) ?: return
        val idleMs = System.currentTimeMillis() - prefs.getLong(KEY_LAST_ACTIVE, 0)
        if (idleMs !in 0..RECOVERY_WINDOW_MS) {
            EventLog.d("sync", "not rejoining $code, it was left ${idleMs / 1000}s ago")
            prefs.edit().remove(KEY_ROOM_CODE).apply()
            return
        }
        // Read before joining: joining writes the listening mode of the new session over these
        val alone = prefs.getBoolean(KEY_ROOM_SOLO, false)
        val aloneOn = prefs.getString(KEY_ROOM_SOLO_ITEM, null)
        val name = prefs.getString(KEY_ROOM_NAME, null) ?: android.os.Build.MODEL
        EventLog.d("sync", "rejoining $code after the process was killed${if (alone) ", on my own" else ""}")
        join(Config.SERVER, code, name, create = false)
        if (alone) session?.restoreSolo(aloneOn)
    }

    /** Change the display name in the current room without interrupting playback. */
    fun rename(name: String) {
        prefs.edit().putString(KEY_ROOM_NAME, name).apply()
        client?.rename(name)
    }

    fun savedName(): String? = prefs.getString(KEY_ROOM_NAME, null)
    fun savedCode(): String? = prefs.getString(KEY_ROOM_CODE, null)

    /** [deliberate]: the person left, so the room is told and an owner hands it over; otherwise the process is just going away. */
    private fun stopFollowing(deliberate: Boolean = true) {
        if (client == null) return
        EventLog.d("sync", "leaving room $roomCode")
        networkCallback?.let { runCatching { context.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it) } }
        networkCallback = null
        if (deliberate) client?.leave() else client?.close()
        session?.close()
        client = null
        session = null
        roomCode = null
        suspended = false
        pending.clear()
        pictures.clear()
        chatLog = null
        chatMore = false
        receiptsLog = emptyMap()
        deliveredUpTo = 0
        scope.cancel()
        scope = newScope()
        fillJob = null
        fillEpoch = null
        owedFill = null
        awake.release("the room was left")
        local.attach() // the personal queue gets the player back, paused where it was
        publish()
    }

    private fun onChat(room: String, message: ServerMessage) {
        when (message) {
            is ServerMessage.ChatHistory -> {
                chatLog = message.msgs.takeLast(CHAT_KEPT)
                receiptsLog = message.receipts
                chatMore = message.more
                _chat.tryEmit(Chat(room, open(room, chatLog.orEmpty()), replace = true, receipts = receiptsLog, more = chatMore))
                chatLog?.lastOrNull()?.let(::acknowledge)
            }
            // Not kept here: the screen holds the pages it asked for, and the log is only what a returning screen is given
            is ServerMessage.ChatPage -> _chat.tryEmit(Chat(room, open(room, message.msgs), replace = false, older = true, more = message.more))
            is ServerMessage.Chat -> {
                val opened = open(room, message.msg)
                // What cannot be read has no words to tell
                if (!opened.locked) ChatNotices.forMessage(opened, room, session?.snapshot?.value?.you)?.let { _chatNotices.tryEmit(it) }
                chatLog = (chatLog.orEmpty() + message.msg).takeLast(CHAT_KEPT)
                _chat.tryEmit(Chat(room, listOf(opened), replace = false))
                acknowledge(message.msg)
            }
            is ServerMessage.ChatUpdate -> {
                val log = chatLog ?: return
                val snapshot = session?.snapshot?.value
                // A message from further back than the log has no earlier version here to tell what is new in it
                val before = log.firstOrNull { it.id == message.msg.id }
                val opened = open(room, message.msg)
                val news = before?.takeIf { !opened.locked }?.let {
                    ChatNotices.forUpdate(it, opened, room, snapshot?.you) { who ->
                        snapshot?.members?.firstOrNull { it.id == who }?.name
                    }
                }
                news?.let { _chatNotices.tryEmit(it) }
                chatLog = log.map { if (it.id == message.msg.id) message.msg else it }
                _chat.tryEmit(Chat(room, listOf(opened), replace = false))
            }
            is ServerMessage.ChatReceipts -> {
                receiptsLog = message.receipts
                _chat.tryEmit(Chat(room, emptyList(), replace = false, receipts = receiptsLog))
            }
            is ServerMessage.React -> _reactions.tryEmit(Reaction(message.by, message.e, message.n))
            else -> Unit
        }
    }

    /**
     * Tells the room that the chat has reached this device up to [last], so that the others can see their message as
     * delivered. The screen need not be on: this is the device having it, not the person having read it.
     */
    private fun acknowledge(last: ChatMessage) {
        if (last.id <= deliveredUpTo) return
        deliveredUpTo = last.id
        // What this device wrote itself needs no word
        if (last.by != session?.snapshot?.value?.you) client?.send(Protocol.chatReceipt(delivered = last.id))
    }

    private fun publish() {
        _view.value = View(
            roomCode,
            client?.connection?.value,
            session?.snapshot?.value ?: GroupSession.Snapshot(),
            local.snapshot.value,
            sealedKey = roomCode?.let { SapocheApp.roomKeys.has(it) } == true,
        )
    }

    /** Sends a command to the room. If the connection was let go of, it is brought back and the command goes when it is up. */
    fun send(text: String): Boolean {
        if (suspended) {
            pending += text
            resumeRoom()
            return true
        }
        return client?.send(text) ?: false
    }

    /**
     * Nobody has listened or looked for a long while: close the connection, because its pings keep the radio
     * awake all day. The room, this device's place in it and whether it listens alone are all kept.
     */
    fun suspendRoom() {
        val c = client ?: return
        if (suspended) return
        suspended = true
        EventLog.d("sync", "nobody is listening or looking, letting go of the connection to $roomCode")
        c.close()
    }

    /** Someone is looking again, or asked for something: connect again. */
    fun resumeRoom() {
        if (!suspended) return
        suspended = false
        EventLog.d("sync", "connecting to $roomCode again")
        client?.start()
    }

    private fun flushPending(target: RoomClient) {
        if (target !== client) return
        pending.forEach { target.send(it) }
        pending.clear()
    }

    /**
     * Play button. If the room is playing and only this device stopped (a phone call, another app took
     * audio focus), resume just this device and let the drift correction catch it up; restarting the
     * whole room would interrupt everyone else.
     */
    fun requestPlay(resumeLocally: () -> Unit) {
        // This device could not load the room's song: load it again rather than press play on nothing
        if (phase() == "playing" && session?.catchUp() == true) return
        val s = session
        // Held back from outside while the room plays on: join the room where it is, not where the sound was lost
        if (s != null && !s.isSolo && phase() == "playing" && (s.isHeld || !exo.playWhenReady)) {
            s.resumeHere()
            return
        }
        if (phase() == "playing" && !exo.playWhenReady) resumeLocally() else requestPlay()
    }

    /**
     * Something outside the app asked this device to pause or stop: a headset button, AirPods taken out, a watch, the
     * notification. In a room it pauses only this device, as when a call takes the sound, because the room is everybody's
     * and such a command cannot tell a person's choice from an ear coming out. Pausing the room is what the buttons in the
     * app do. Stopping the player under the queue would leave play doing nothing, so a stop pauses too.
     */
    fun pauseFromOutside() {
        val s = session
        if (s == null || s.isSolo) {
            requestPause()
        } else {
            s.hold()
            exo.pause()
        }
    }

    /**
     * This device follows a room that is playing but its own player is paused: a headset, a call or an app that took the
     * sound did that here and the room plays on. The play button then shows play, and resumes only this device.
     */
    private fun heldBack(): Boolean {
        val s = session ?: return false
        val silent = !exo.playWhenReady || exo.playbackSuppressionReason != Player.PLAYBACK_SUPPRESSION_REASON_NONE
        return !s.isSolo && phase() == "playing" && (s.isHeld || (s.isInSync && silent))
    }

    /** Listening on this device alone: the room does not move it, and its buttons do not move the room. */
    val isSolo: Boolean get() = session?.isSolo == true

    /** Stop following the room and carry on alone. */
    fun goSolo() {
        session?.goSolo()
    }

    /** Follow the room again. */
    fun rejoin() {
        session?.rejoin()
    }

    /** The room stopped and this device wants to go on: leave the room's transport and resume. */
    fun keepPlaying() {
        val s = session ?: return
        s.goSolo()
        s.soloPlay()
    }

    // Outside a room the buttons drive the personal queue; in a room they act on the room, or on this device alone
    fun requestPlay(): Boolean {
        session?.unhold()
        return act({ it.play() }, { it.soloPlay() }) { send(Protocol.play()) }
    }
    fun requestPause(): Boolean = act({ it.pause() }, { it.soloPause() }) { send(Protocol.pause()) }
    // Each names the song it was pressed on, so that it does nothing once somebody else already skipped it
    fun requestNext(): Boolean = act({ it.next() }, { it.soloNext() }) { send(Protocol.next(roomItemId())) }
    fun requestPrev(): Boolean = act({ it.prev() }, { it.soloPrev() }) { send(Protocol.prev(roomItemId())) }
    private fun roomItemId(): String? = session?.snapshot?.value?.state?.current?.id
    fun requestSeek(positionMs: Long): Boolean = act({ it.seek(positionMs) }, { it.soloSeek(positionMs) }) { send(Protocol.seek(positionMs)) }
    fun requestJump(itemId: String): Boolean = act({ it.jump(itemId) }, { it.soloJump(itemId) }) { send(Protocol.jump(itemId)) }

    /** The queue is the room's in a room, even while listening alone, and the personal one outside. */
    private inline fun onQueue(onLocal: (LocalSession) -> Unit, onRoom: () -> Boolean): Boolean {
        if (session == null) {
            onLocal(local)
            return true
        }
        return onRoom()
    }

    fun requestClearQueue() = onQueue({ it.clear() }) { send(Protocol.queueClear()) }
    fun requestClearQueued() = onQueue({ it.clearQueued() }) { false }
    fun requestShuffle() = onQueue({ it.shuffle() }) { send(Protocol.queueShuffle()) }
    /** Shuffle as a mode. A server older than protocol 11 has none, so there it mixes the queue once, as it always did. */
    fun requestShuffleMode(on: Boolean) = onQueue({ it.setShuffle(on) }) {
        if (session?.snapshot?.value?.state?.shuffle == null) {
            if (on) send(Protocol.queueShuffle()) else true
        } else {
            send(Protocol.shuffle(on))
        }
    }
    fun requestRepeat(mode: String) = onQueue({ it.setRepeat(mode) }) { send(Protocol.repeat(mode)) }
    fun requestAddMany(tracks: List<TrackRef>, playNext: Boolean, source: String = ListenSource.CHOSEN, queued: Boolean = true): Boolean {
        sources.mark(tracks.map { it.videoId }, source)
        return addToQueue(tracks, playNext, queued)
    }

    /** Outside a room [tracks] become the queue and play from song [start]; a room's queue is shared, so they are only added to it. */
    /**
     * The personal queue as another device of this person can take it over (Connect), as `{"dropped":n,"saved":{...}}`; null in a
     * room, whose queue is everybody's. The songs of this device's own music are left out and counted.
     */
    fun exportQueueJson(): String? {
        if (session != null) return null
        val handover = local.exportQueue()
        return """{"dropped":${handover.dropped},"saved":${Protocol.json.encodeToString(handover.saved)}}"""
    }

    /** Takes the JSON of a queue [exportQueueJson] made on another device as the personal queue; false in a room or when it is not one. */
    fun importQueueJson(json: String, play: Boolean): Boolean {
        if (session != null) return false
        val saved = try {
            Protocol.json.decodeFromString<SavedQueue>(json)
        } catch (_: SerializationException) {
            return false
        } catch (_: IllegalArgumentException) {
            return false
        }
        local.importQueue(saved, play)
        return true
    }

    fun requestPlayList(tracks: List<TrackRef>, start: Int, label: String? = null, source: String = ListenSource.CHOSEN): Boolean {
        sources.mark(tracks.map { it.videoId }, source)
        return onQueue({ it.playList(tracks, start, label) }) { addToQueue(tracks, playNext = false) }
    }

    private fun addToQueue(tracks: List<TrackRef>, playNext: Boolean, queued: Boolean = true) = onQueue({ it.add(tracks, playNext, queued = queued) }) {
        // What is waiting in the room's queue is not added twice
        val fresh = Queues.fresh(tracks, queue(), session?.snapshot?.value?.state?.index ?: 0)
        fresh.isEmpty() || send(Protocol.queueAddMany(fresh, playNext))
    }
    /**
     * Plays [track], another release of the song, in place of the queue item [itemId]. What is playing carries on while
     * the new release is made ready (its addresses are found and tried), so that the sound is cut only for the time the
     * first of its data takes, not for all of the lookup as well.
     */
    suspend fun requestSwap(itemId: String, track: TrackRef): Boolean {
        SapocheApp.mediaData.warm(track.videoId, videoMode)
        return onQueue({ it.swap(itemId, track) }) { send(Protocol.queueSwap(itemId, track)) }
    }
    fun requestRemove(itemId: String) = onQueue({ it.remove(itemId) }) { send(Protocol.queueRemove(itemId)) }
    fun requestMove(itemId: String, toIndex: Int, queued: Boolean? = null) = onQueue({ it.move(itemId, toIndex, queued) }) { send(Protocol.queueMove(itemId, toIndex)) }

    // Only meaningful in a room
    fun requestKick(memberId: String) = send(Protocol.kick(memberId))
    fun requestRoomName(name: String) = send(Protocol.roomName(name))
    fun requestRoomTheme(theme: String, bg: String?): Boolean {
        val code = roomCode ?: return false
        if (session?.snapshot?.value?.state?.enc != true) return send(Protocol.roomTheme(theme, bg))
        // A sealed room keeps the picture sealed: without the secret there is nothing to send, and a clear one is not taken
        val secret = SapocheApp.roomKeys.get(code) ?: return false
        val sealed = bg?.let { ChatCipher.sealBackground(secret, code, Base64.decode(it, Base64.DEFAULT)) }
        return send(Protocol.roomTheme(theme, sealed, sealed = true))
    }

    /** Tickets for [sizes] files, or the code of the error the room answered with (`media_full`, ...) or `offline`. */
    suspend fun mediaTickets(sizes: List<Long>): Map<String, Any?> {
        val id = java.util.UUID.randomUUID().toString()
        val answer = CompletableDeferred<ServerMessage>()
        ticketWaiters[id] = answer
        try {
            if (client?.send(Protocol.mediaPut(sizes, id)) != true) return mapOf("error" to "offline")
            return when (val message = withTimeoutOrNull(TICKET_WAIT_MS) { answer.await() }) {
                is ServerMessage.MediaTicket -> mapOf("tickets" to message.tickets.map { mapOf("m" to it.m, "url" to it.url, "token" to it.token) })
                is ServerMessage.Error -> mapOf("error" to message.code)
                else -> mapOf("error" to "offline")
            }
        } finally {
            ticketWaiters.remove(id)
        }
    }
    fun requestRoomSettings(guestControl: String) = send(Protocol.roomSettings(guestControl))
    fun requestRoomAutoplay(on: Boolean) = send(Protocol.autoplay(on))
    fun requestRoomWaitWeak(on: Boolean) = send(Protocol.waitWeak(on))

    /** Runs the action for wherever the buttons act: outside a room, alone in a room, or on the room itself. */
    private inline fun act(onLocal: (LocalSession) -> Unit, onSolo: (GroupSession) -> Unit, onRoom: () -> Boolean): Boolean {
        val s = session
        return when {
            s == null -> {
                onLocal(local)
                true
            }
            s.isSolo -> {
                onSolo(s)
                true
            }
            else -> onRoom()
        }
    }

    /** The room's current queue, for callers that need item ids. */
    fun queue(): List<app.sapoche.sync.QueueItem> = session?.snapshot?.value?.state?.queue ?: emptyList()

    fun setTrim(ms: Long) {
        trimMs = ms.coerceIn(-MAX_TRIM_MS, MAX_TRIM_MS)
        prefs.edit().putLong(KEY_TRIM_MS, trimMs).apply()
        session?.trimMs = trimMs
        EventLog.d("sync", "latency trim ${trimMs}ms")
    }

    /** Diagnostics: turn drift correction off to observe the raw drift. */
    fun setCorrection(enabled: Boolean) {
        session?.correctionEnabled = enabled
        EventLog.d("sync", "drift correction ${if (enabled) "on" else "off"}")
    }

    data class PlayerInfo(
        val playing: Boolean,
        val buffering: Boolean,
        val positionMs: Long,
        val durationMs: Long,
        val videoWidth: Int = 0,
        val videoHeight: Int = 0,
        /** The picture is wanted but this song plays without one. */
        val noPicture: Boolean = false,
        /** Paused on this device while the room plays on, see [heldBack]. */
        val heldBack: Boolean = false,
        /** How fast the player plays: the person's choice outside a room, the drift control's in one. */
        val speed: Float = 1f,
        /** Codec, average bitrate and sample rate of the audio stream currently playing; null until known. */
        val audioFormat: app.sapoche.core.AudioFormat? = null,
    )

    /** Snapshot of the local player for the UI; call on the main thread. */
    fun playerInfo(): PlayerInfo {
        // After a restart the queue is back but nothing is loaded: show where the song will resume
        val restored = if (roomCode == null) local.restoredPositionMs else null
        if (restored != null) {
            return PlayerInfo(playing = false, buffering = false, positionMs = restored, durationMs = local.snapshot.value.current?.durMs ?: 0)
        }
        return PlayerInfo(
            playing = exo.isPlaying,
            buffering = exo.playbackState == Player.STATE_BUFFERING,
            positionMs = exo.currentPosition.coerceAtLeast(0),
            durationMs = exo.duration.coerceAtLeast(0),
            videoWidth = exo.videoSize.width,
            videoHeight = exo.videoSize.height,
            noPicture = port.pictureMissing(),
            heldBack = heldBack(),
            speed = exo.playbackParameters.speed,
            audioFormat = port.audioFormat(),
        )
    }

    fun addPlayerListener(listener: Player.Listener) = exo.addListener(listener)
    fun removePlayerListener(listener: Player.Listener) = exo.removeListener(listener)

    /** Resume only this device's player, see [requestPlay]. */
    fun playLocally() = exo.play()

    /** Phase of the room as last announced by the server, or null when not joined. */
    fun phase(): String? = session?.snapshot?.value?.state?.phase

    /** One-line summary for the test UI. */
    fun describe(): String {
        val c = client ?: return "not in a room"
        val snap = session?.snapshot?.value
        val state = snap?.state
        val current = state?.current?.title ?: "-"
        return "room $roomCode ${c.connection.value} | ${snap?.members?.size ?: 0} member(s) | " +
            "phase=${state?.phase} epoch=${state?.epoch} queue=${state?.queue?.size ?: 0} | $current" +
            "${if (snap?.solo == true) " | ALONE" else ""}\n" +
            "drift=${snap?.driftMs?.let { "%+dms".format(it) } ?: "-"} speed=${snap?.speed} trim=${trimMs}ms " +
            "clockOffset=${clock.offsetMs().toLong()}ms rtt=${clock.bestRttMs()?.toLong() ?: "-"}ms"
    }

    fun release() {
        stopFollowing(deliberate = false) // keep the saved room so a restart soon after rejoins it
        awake.release("the service stops")
        forgetOwedAutoplay("the service stops")
        local.save()
        ownScope.cancel()
        scope.cancel()
        // Let the last write of the queue finish
        writer.shutdown()
        writer.awaitTermination(2, TimeUnit.SECONDS)
    }

    /** Stable per-install id, so a reconnecting device replaces its own stale socket. */
    private fun deviceId(): String =
        prefs.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString(KEY_DEVICE_ID, it).apply()
        }

    private fun newScope() = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** How the screen knows why this device could not load a song, see [LocalSession.Problem.Kind]. */
    private fun loadFailureCode(reason: LoadFailure.Reason?): String = when (reason) {
        LoadFailure.Reason.OFFLINE -> LocalSession.Problem.Kind.OFFLINE.code
        LoadFailure.Reason.UNPLAYABLE -> LocalSession.Problem.Kind.UNPLAYABLE.code
        null -> LocalSession.Problem.Kind.FAILED.code
    }

    private companion object {
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_ROOM_CODE = "room_code"
        const val KEY_ROOM_NAME = "room_name"
        const val KEY_AVATAR = "avatar"
        const val KEY_ROOM_SOLO = "room_solo"
        const val KEY_ROOM_SOLO_ITEM = "room_solo_item"
        const val KEY_LAST_ACTIVE = "room_last_active"
        const val KEY_VIDEO = "video_mode"
        const val KEY_NORMALIZE = "normalize_volume"
        const val KEY_CROSSFADE = "crossfade_seconds"
        const val KEY_AUTOPLAY = "autoplay"
        const val KEY_SHARE_TASTE = "share_taste"
        const val TASTE_PROTOCOL = 19
        const val TASTE_TEXT = 200
        const val TASTE_DELAY_MS = 3_000L
        const val MIN_SPEED = 0.25f
        const val MAX_SPEED = 2f

        /** Songs added each time the queue runs out and the music carries on by itself. */
        const val AUTOPLAY_COUNT = 5

        /** How long after the last try of autoplay in vain a network coming back earns it one more round. */
        const val AUTOPLAY_OWED_MS = 5 * 60_000L

        /** Songs that follow one that was played on its own. */
        const val RADIO_COUNT = 20
        const val KEY_TRIM_MS = "trim_ms"
        const val KEY_START_BIAS_MS = "start_bias_ms"
        const val MAX_TRIM_MS = 1000L

        /** How often the time of the last sign of life is written down while in a room. */
        const val ACTIVE_STAMP_MS = 60_000L

        /** A room is rejoined after a restart only if this device was in it this recently. */
        const val RECOVERY_WINDOW_MS = 10 * 60_000L

        /** The chat messages kept, as many as the room keeps. */
        const val CHAT_KEPT = 100
        /** How long a request for tickets waits for the room. */
        const val TICKET_WAIT_MS = 15_000L
    }
}
