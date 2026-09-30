package app.unison.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlin.random.Random

/** What is kept of the personal queue between runs. */
@Serializable
data class SavedQueue(
    val queue: List<QueueItem> = emptyList(),
    val index: Int = 0,
    val repeat: String = "off",
    /** Where the current item resumes. */
    val positionMs: Long = 0,
    val finished: Boolean = false,
)

/** [SavedQueue] as one JSON file. A write goes to a temporary file first, so a crash never leaves half a queue. */
class QueueFile(private val file: File) {

    fun read(): SavedQueue? = try {
        Protocol.json.decodeFromString<SavedQueue>(file.readText())
    } catch (_: IOException) {
        null
    } catch (_: SerializationException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }

    fun write(saved: SavedQueue) {
        val temporary = File(file.path + ".tmp")
        temporary.writeText(Protocol.json.encodeToString(saved))
        if (!temporary.renameTo(file)) {
            file.delete()
            temporary.renameTo(file)
        }
    }
}

/**
 * The queue a person listens to outside a room: an ordinary music player's queue that lives on this
 * device and survives restarts. It drives the same [PlayerPort] as [GroupSession] and never talks to
 * the server. Only one of the two owns the player at a time; [attach] and [detach] hand it over.
 *
 * [scope] must run on a single thread, like the one given to [GroupSession].
 */
class LocalSession(
    private val scope: CoroutineScope,
    private val player: PlayerPort,
    saved: SavedQueue?,
    /** Called whenever what should be remembered changed. */
    private val persist: (SavedQueue) -> Unit,
    /** Something the person should be told, e.g. a song that would not load. */
    private val problem: (String) -> Unit = {},
    private val log: (String) -> Unit = {},
    /** The queue ran out of songs after [QueueItem] (it played through, or next was pressed on the last one). */
    private val onQueueEnd: (QueueItem) -> Unit = {},
    private val newId: () -> String = { UUID.randomUUID().toString() },
    private val random: Random = Random.Default,
) {
    data class Snapshot(
        val queue: List<QueueItem> = emptyList(),
        val index: Int = 0,
        /** off, all or one, like the room's repeat. */
        val repeat: String = "off",
        /** The queue ran out: nothing is playing, and play starts it again from the top. */
        val finished: Boolean = false,
    ) {
        val current: QueueItem? get() = queue.getOrNull(index)
    }

    private val _snapshot = MutableStateFlow(restore(saved))
    val snapshot: StateFlow<Snapshot> = _snapshot.asStateFlow()

    /** Queue item loaded in the player; null after a restart until something is played. */
    private var loadedId: String? = null

    /** Where the current item resumes once it is loaded. */
    private var pendingPositionMs = if (saved?.finished == true) 0 else saved?.positionMs ?: 0

    /** Item handed to the player as the gapless successor of the loaded one. */
    private var preloaded: QueueItem? = null
    private var job: Job? = null

    /** Reloads used on the current item; stops endless retry loops on a broken stream. */
    private var recoveries = 0

    /** Whether the item being loaded starts playing once it is ready; play and pause during a load only flip this. */
    private var playOnLoad = false

    /**
     * Position to show for the current item while nothing is loaded (after a restart), else null: the
     * player knows better then.
     */
    val restoredPositionMs: Long? get() = if (loadedId == null && snapshot.value.current != null) pendingPositionMs else null

    /** Take the player over: from now on its endings and errors are ours. Loads nothing. */
    fun attach() {
        // Only the end of a song this session loaded counts: a player that has nothing (a restart brought the service
        // back from a media button) also reports "ended", and that must not finish the saved queue
        player.onEnded = { scope.launch { if (loadedId != null) step(+1, auto = true) } }
        player.onAdvanced = { scope.launch { onAdvanced() } }
        player.onError = { error -> scope.launch { onPlayerError(error) } }
    }

    /** A room takes the player: silence it, but remember where this queue stood so it can be picked up again. */
    fun detach() {
        job?.cancel()
        if (loadedId != null) pendingPositionMs = player.positionMs()
        loadedId = null
        preloaded = null
        player.stop()
        save()
    }

    // ------------------------------------------------------------------ transport

    fun play() {
        val s = snapshot.value
        when {
            // Asked twice (a button and the media session both do): the item is on its way, do not start over
            loadedId == null && job?.isActive == true -> playOnLoad = true
            loadedId != null -> player.play()
            s.queue.isEmpty() -> Unit
            // After the last song, play means "again": from the top of the list
            s.finished -> load(s.queue[0], 0, play = true)
            else -> load(s.queue[s.index], pendingPositionMs, play = true)
        }
    }

    fun pause() {
        playOnLoad = false
        player.pause()
        save()
    }

    fun seek(positionMs: Long) {
        val target = positionMs.coerceAtLeast(0)
        if (loadedId == null) {
            pendingPositionMs = target
            return
        }
        scope.launch { player.seekTo(target) }
    }

    fun next() = step(+1, auto = false)

    /** Restart this song, or go to the one before it when it has only just begun. */
    fun prev() {
        if (loadedId != null && player.positionMs() > PREV_RESTARTS_AFTER_MS) seek(0) else step(-1, auto = false)
    }

    fun jump(id: String) {
        snapshot.value.queue.firstOrNull { it.id == id }?.let { load(it, 0, play = true) }
    }

    // ------------------------------------------------------------------ queue

    /** Adds songs at the end, or right after the current one with [next]. With nothing to play, the first one starts. */
    fun add(tracks: List<TrackRef>, next: Boolean) {
        val s = snapshot.value
        val room = MAX_QUEUE - s.queue.size
        if (tracks.isNotEmpty() && room <= 0) return problem("The queue is full")
        val items = tracks.take(room).map { QueueItem(newId(), it.videoId, it.title, it.artist, it.thumb, it.durMs, addedBy = "") }
        if (items.isEmpty()) return

        val startNow = s.queue.isEmpty() || s.finished
        val at = if (next && !startNow) s.index + 1 else s.queue.size
        val queue = s.queue.toMutableList().also { it.addAll(at, items) }
        _snapshot.update { it.copy(queue = queue) }
        if (startNow) load(items.first(), 0, play = true) else preload()
        save()
    }

    fun remove(id: String) {
        val s = snapshot.value
        val at = s.queue.indexOfFirst { it.id == id }
        if (at < 0) return
        val queue = s.queue.toMutableList().also { it.removeAt(at) }
        when {
            at < s.index -> _snapshot.update { it.copy(queue = queue, index = s.index - 1) }
            at > s.index -> _snapshot.update { it.copy(queue = queue) }
            queue.isEmpty() -> {
                stopPlayer()
                _snapshot.update { Snapshot(repeat = it.repeat) }
            }
            at < queue.size -> {
                // The next song takes the place of the one removed, and plays if that one was playing
                val play = loadedId == id && player.isPlaying()
                _snapshot.update { it.copy(queue = queue) }
                if (loadedId == id) load(queue[at], 0, play) else pendingPositionMs = 0
            }
            else -> {
                stopPlayer()
                _snapshot.update { it.copy(queue = queue, index = queue.size - 1, finished = true) }
            }
        }
        preload()
        save()
    }

    fun move(id: String, toIndex: Int) {
        val s = snapshot.value
        val from = s.queue.indexOfFirst { it.id == id }
        if (from < 0) return
        val currentId = s.current?.id
        val queue = s.queue.toMutableList()
        queue.add(toIndex.coerceIn(0, queue.size - 1), queue.removeAt(from))
        val index = if (currentId == null) 0 else queue.indexOfFirst { it.id == currentId }.coerceAtLeast(0)
        _snapshot.update { it.copy(queue = queue, index = index) }
        preload()
        save()
    }

    fun clear() {
        stopPlayer()
        _snapshot.update { Snapshot(repeat = it.repeat) }
        save()
    }

    /**
     * Mixes up what is still to come, so the song playing carries on. Once the queue has finished it
     * mixes the whole list and plays from the top: the way to hear it again in a new order.
     */
    fun shuffle() {
        val s = snapshot.value
        if (s.queue.size < 2) return
        val queue = s.queue.toMutableList()
        if (s.finished) {
            queue.shuffle(random)
            _snapshot.update { it.copy(queue = queue) }
            load(queue[0], 0, play = true)
        } else {
            queue.subList(s.index + 1, queue.size).shuffle(random)
            _snapshot.update { it.copy(queue = queue) }
            preload()
        }
        save()
    }

    fun setRepeat(mode: String) {
        if (mode != "off" && mode != "all" && mode != "one") return
        if (mode == snapshot.value.repeat) return
        _snapshot.update { it.copy(repeat = mode) }
        preload()
        save()
    }

    /** Writes down the queue and where it stands; called on every change and when playback stops. */
    fun save() {
        val s = snapshot.value
        val position = if (loadedId != null) player.positionMs() else pendingPositionMs
        persist(SavedQueue(s.queue, s.index, s.repeat, position, s.finished))
    }

    // ------------------------------------------------------------------ playing

    /** Moves [delta] items along the queue; at the ends it wraps when repeating all, and otherwise stops. */
    private fun step(delta: Int, auto: Boolean) {
        val s = snapshot.value
        if (s.queue.isEmpty()) return
        var target = if (s.finished && delta < 0) s.index else s.index + delta
        if (auto && s.repeat == "one") target = s.index
        if (target >= s.queue.size) target = if (s.repeat == "all") 0 else -1
        if (target < 0) {
            if (delta < 0) target = 0 else return finish()
        }
        load(s.queue[target], 0, play = true)
    }

    /** Ran out of songs: nothing is current until play starts the list again. */
    private fun finish() {
        val last = snapshot.value.queue.lastOrNull()
        stopPlayer()
        _snapshot.update { it.copy(index = it.queue.size - 1, finished = true) }
        save()
        last?.let(onQueueEnd)
    }

    private fun stopPlayer() {
        job?.cancel()
        player.stop()
        loadedId = null
        preloaded = null
        pendingPositionMs = 0
    }

    private fun load(item: QueueItem, positionMs: Long, play: Boolean) {
        job?.cancel()
        preloaded = null
        loadedId = null
        val at = snapshot.value.queue.indexOfFirst { it.id == item.id }
        if (at < 0) return
        if (at != snapshot.value.index) recoveries = 0
        // The person sees the new song at once, not when it has loaded
        _snapshot.update { it.copy(index = at, finished = false) }
        playOnLoad = play
        job = scope.launch {
            try {
                player.prepare(item, positionMs)
                loadedId = item.id
                pendingPositionMs = 0
                if (playOnLoad) player.play()
                preload()
                save()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("could not load '${item.title}': ${e.message}")
                pendingPositionMs = positionMs
                problem("Could not load: ${item.title}")
            }
        }
    }

    /** Keeps the gapless successor equal to the song after the one loaded. */
    private fun preload() {
        val s = snapshot.value
        val wanted = if (loadedId != null && s.current?.id == loadedId && s.repeat != "one") s.queue.getOrNull(s.index + 1) else null
        if (wanted?.id == preloaded?.id) return
        preloaded = wanted
        player.setNext(wanted)
    }

    /** The player moved on to the successor by itself. */
    private fun onAdvanced() {
        val item = preloaded ?: return
        val at = snapshot.value.queue.indexOfFirst { it.id == item.id }
        if (at < 0) return
        preloaded = null
        loadedId = item.id
        pendingPositionMs = 0
        recoveries = 0
        _snapshot.update { it.copy(index = at) }
        preload()
        save()
    }

    /** The stream broke while playing: load it again where it stopped, and after a few tries move on. */
    private fun onPlayerError(error: Exception) {
        val item = snapshot.value.current?.takeIf { it.id == loadedId } ?: return
        if (++recoveries > MAX_RECOVERIES) {
            log("player error, giving up on '${item.title}' after $MAX_RECOVERIES tries: ${error.message}")
            problem("Could not play: ${item.title}")
            recoveries = 0
            return step(+1, auto = true)
        }
        log("player error, loading '${item.title}' again (#$recoveries): ${error.message}")
        load(item, player.positionMs(), play = true)
    }

    private fun restore(saved: SavedQueue?): Snapshot {
        if (saved == null) return Snapshot()
        val queue = saved.queue.take(MAX_QUEUE)
        return Snapshot(
            queue = queue,
            index = saved.index.coerceIn(0, maxOf(0, queue.size - 1)),
            repeat = saved.repeat.takeIf { it == "all" || it == "one" } ?: "off",
            finished = saved.finished && queue.isNotEmpty(),
        )
    }

    private companion object {
        const val MAX_QUEUE = 200
        const val MAX_RECOVERIES = 3
        const val PREV_RESTARTS_AFTER_MS = 3000L
    }
}
