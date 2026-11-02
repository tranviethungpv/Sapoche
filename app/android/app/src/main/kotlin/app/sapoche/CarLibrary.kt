package app.sapoche

import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import app.sapoche.sync.QueueItem
import app.sapoche.sync.TrackRef

/** A room this device has been in; [members] is how many are in it now, null when the server could not say. */
data class CarRoom(val code: String, val name: String?, val members: Int?)

/**
 * What a car's screen (Android Auto) is offered to browse and play: the queue that is playing, the rooms, the library and
 * what is suggested. Every item has the id `<where>|<what>`: a song is `liked|<video id>`, a room is `room|<code>`, a
 * folder is just its name. Playing a song of a list plays the list from there, as in the app, and a search (also by
 * voice) plays what it found. Picking a room joins it.
 *
 * Only songs outside a room replace the queue; in a room a song picked in the car is added to the room's queue.
 */
class CarLibrary(
    private val library: LibraryStore,
    private val queue: () -> List<QueueItem>,
    private val search: suspend (String) -> List<TrackRef>,
    private val vietnamese: () -> Boolean,
    private val rooms: suspend () -> List<CarRoom> = { emptyList() },
    private val suggested: suspend () -> List<TrackRef> = { emptyList() },
) {
    /** What the last search found, which "found" songs are played from. */
    private var found: List<TrackRef> = emptyList()

    /** What the "For you" tab showed last, which its songs are played from. */
    private var offered: List<TrackRef> = emptyList()

    private fun text(vi: String, en: String) = if (vietnamese()) vi else en

    fun root(): MediaItem = folder(ROOT, "Sapoche")

    private fun folder(id: String, title: String): MediaItem = MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(title)
                .setIsBrowsable(true)
                .setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED)
                .build(),
        )
        .build()

    private fun song(where: String, id: String, track: TrackRef): MediaItem = MediaItem.Builder()
        .setMediaId("$where|$id")
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(track.title)
                .setArtist(track.artist)
                .apply { track.thumb?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                .setDurationMs(track.durMs.takeIf { it > 0 })
                .setIsBrowsable(false)
                .setIsPlayable(true)
                .setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
                .build(),
        )
        .build()

    private fun songs(where: String, tracks: List<TrackRef>) = tracks.map { song(where, it.videoId, it) }

    /** A room is a playable item whose playing is joining it. */
    private fun room(room: CarRoom): MediaItem = MediaItem.Builder()
        .setMediaId("$ROOM|${room.code}")
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(room.name ?: room.code)
                .setSubtitle(room.members?.let { text("$it người đang nghe", if (it == 1) "1 listening" else "$it listening") })
                .setIsBrowsable(false)
                .setIsPlayable(true)
                .setMediaType(MediaMetadata.MEDIA_TYPE_MIXED)
                .build(),
        )
        .build()

    /**
     * What stands in a list with nothing in it. A car says only "No items" for an empty folder, so the list holds one line that
     * is not a song and says what to do; it can be neither opened nor played.
     */
    private fun hint(where: String, vi: String, en: String, subVi: String, subEn: String): MediaItem = MediaItem.Builder()
        .setMediaId("$INFO|$where")
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(text(vi, en))
                .setSubtitle(text(subVi, subEn))
                .setIsBrowsable(false)
                .setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_MIXED)
                .build(),
        )
        .build()

    private fun List<MediaItem>.orHint(where: String, vi: String, en: String, subVi: String, subEn: String) =
        ifEmpty { listOf(hint(where, vi, en, subVi, subEn)) }

    /** The items inside folder [parent], or null when there is no such folder. */
    suspend fun children(parent: String): List<MediaItem>? = when {
        parent == ROOT -> listOf(
            folder(NOW, text("Đang nghe", "Now playing")),
            folder(ROOMS, text("Phòng", "Rooms")),
            folder(LIBRARY, text("Thư viện", "Library")),
            folder(FOR_YOU, text("Cho bạn", "For you")),
        )
        parent == NOW -> queue().map { song(NOW, it.id, TrackRef(it.videoId, it.title, it.artist, it.thumb, it.durMs)) }
            .orHint(NOW, "Hàng đợi đang trống", "The queue is empty", "Chọn bài ở Thư viện hoặc Cho bạn", "Pick a song in Library or For you")
        parent == LIBRARY -> listOf(
            folder(LIKED, text("Bài đã thích", "Liked songs")),
            folder(RECENT, text("Nghe gần đây", "Recently played")),
            folder(PLAYLISTS, text("Danh sách phát", "Playlists")),
        )
        parent == ROOMS -> rooms().map(::room)
            .orHint(ROOMS, "Chưa có phòng nào", "No rooms yet", "Tạo hoặc vào một phòng trong ứng dụng", "Start or join a room in the app")
        parent == FOR_YOU -> songs(FOR_YOU, forYou())
            .orHint(FOR_YOU, "Chưa có gợi ý", "No suggestions yet", "Nghe thêm vài bài để có gợi ý", "Play a few songs to get suggestions")
        parent == LIKED -> songs(LIKED, library.liked().map { it.track })
            .orHint(LIKED, "Chưa có bài đã thích", "No liked songs yet", "Bấm ♥ ở màn đang phát", "Tap ♥ on the playing screen")
        parent == RECENT -> songs(RECENT, library.recent().map { it.track })
            .orHint(RECENT, "Chưa nghe bài nào", "Nothing played yet", "Bài vừa nghe sẽ hiện ở đây", "Songs you play show up here")
        parent == PLAYLISTS -> library.playlists().map { folder("$PLAYLIST_PREFIX${it.id}", it.name) }
            .orHint(PLAYLISTS, "Chưa có danh sách phát", "No playlists yet", "Tạo danh sách phát trong ứng dụng", "Create a playlist in the app")
        parent.startsWith(PLAYLIST_PREFIX) -> parent.removePrefix(PLAYLIST_PREFIX).toLongOrNull()?.let {
            songs(parent, library.playlistTracks(it)).orHint(parent, "Danh sách này đang trống", "This playlist is empty", "Thêm bài vào trong ứng dụng", "Add songs in the app")
        }
        else -> null
    }

    /** One item by its id: a folder, or a song of a list. */
    suspend fun item(id: String): MediaItem? {
        if (id == ROOT) return root()
        val (where, what) = split(id)
        if (where == ROOM && what != null) return rooms().firstOrNull { it.code == what }?.let(::room)
        if (what != null) return context(where)?.firstOrNull { it.videoId == what }?.let { song(where, what, it) }
        return (children(ROOT).orEmpty() + children(LIBRARY).orEmpty() + children(PLAYLISTS).orEmpty()).firstOrNull { it.mediaId == id }
    }

    /** What searching for [query] finds, as songs to play; the last search is what "found" songs belong to. */
    suspend fun find(query: String): List<MediaItem> {
        found = runCatching { search(query) }.getOrDefault(emptyList()).take(SEARCH_LIMIT)
        return songs(FOUND, found)
    }

    /** What is suggested now; it is what the "For you" songs are played from until it is asked again. */
    private suspend fun forYou(): List<TrackRef> = runCatching { suggested() }.getOrDefault(emptyList()).also { offered = it }

    /** The songs of a list a song can be played from, or null when [where] is not one. */
    private suspend fun context(where: String): List<TrackRef>? = when {
        where == FOR_YOU -> offered.ifEmpty { forYou() }
        where == LIKED -> library.liked().map { it.track }
        where == RECENT -> library.recent().map { it.track }
        where == FOUND -> found
        where.startsWith(PLAYLIST_PREFIX) -> where.removePrefix(PLAYLIST_PREFIX).toLongOrNull()?.let { library.playlistTracks(it) }
        else -> null
    }

    /**
     * What the player is given when a controller asks for [items]: a single song of a list becomes the whole list, started
     * at that song, and a spoken or typed request with no id is searched for. Null leaves the items as they were.
     */
    suspend fun expand(items: List<MediaItem>, startIndex: Int): Pair<List<MediaItem>, Int>? {
        val first = items.singleOrNull() ?: return null
        if (first.mediaId.isEmpty()) {
            val query = first.requestMetadata.searchQuery?.takeIf { it.isNotBlank() } ?: return null
            return find(query).takeIf { it.isNotEmpty() }?.let { it to 0 }
        }
        val (where, what) = split(first.mediaId)
        if (what == null || where == NOW) return null
        val tracks = context(where) ?: return null
        val at = tracks.indexOfFirst { it.videoId == what }
        if (at < 0) return null
        return songs(where, tracks) to at
    }

    companion object {
        const val ROOT = "root"
        const val NOW = "now"
        const val ROOMS = "rooms"
        const val ROOM = "room"
        const val LIBRARY = "library"
        const val FOR_YOU = "foryou"
        const val LIKED = "liked"
        const val RECENT = "recent"
        const val PLAYLISTS = "playlists"
        const val FOUND = "found"

        /** The id of the line that says a list is empty; it is not a song and not a folder. */
        const val INFO = "info"
        const val PLAYLIST_PREFIX = "pl-"
        private const val SEARCH_LIMIT = 15

        /** `liked|abc` is `liked` and `abc`; an id with no `|` is a folder (or a bare video id) and has no second part. */
        fun split(mediaId: String): Pair<String, String?> {
            val bar = mediaId.indexOf('|')
            return if (bar < 0) mediaId to null else mediaId.substring(0, bar) to mediaId.substring(bar + 1)
        }

        /** The code of the room an item stands for, or null when it is not a room. */
        fun roomCode(item: MediaItem): String? = split(item.mediaId).let { (where, what) -> if (where == ROOM) what else null }

        /** The song an item stands for, from what its id and details say. */
        fun track(item: MediaItem): TrackRef {
            val id = split(item.mediaId).let { (_, what) -> what ?: item.mediaId }
            val meta = item.mediaMetadata
            return TrackRef(id, meta.title?.toString().orEmpty(), meta.artist?.toString().orEmpty(), meta.artworkUri?.toString(), meta.durationMs ?: 0L)
        }
    }
}
