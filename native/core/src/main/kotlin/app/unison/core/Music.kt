package app.unison.core

/**
 * A song as YouTube Music describes it. [isSong] tells its audio release ("Song", art track) from a video of
 * it (official clip, or one somebody else uploaded); [counterpart] is the other one when YouTube says which.
 */
data class MusicTrack(
    val videoId: String,
    val title: String,
    val artist: String,
    val artistId: String? = null,
    val album: String? = null,
    val albumId: String? = null,
    val year: String? = null,
    val durationSec: Long = 0,
    val thumbUrl: String? = null,
    val isSong: Boolean = false,
    val counterpart: MusicTrack? = null,
)

/** An artist, or a channel that puts music out. */
data class ArtistCard(val id: String, val name: String, val subtitle: String?, val thumbUrl: String?)

data class AlbumCard(val id: String, val title: String, val subtitle: String?, val thumbUrl: String?)

data class PlaylistCard(val id: String, val title: String, val subtitle: String?, val thumbUrl: String?)

/**
 * What plays after a song: [tracks] is the radio of the song, the song itself first. The other two are where
 * the lyrics and the "related" page of this song are asked for, when it has them.
 */
data class WatchNext(val tracks: List<MusicTrack>, val lyricsId: String?, val relatedId: String?)

/** The "related" page of a song. */
data class Related(
    val more: List<MusicTrack>,
    val otherPerformances: List<MusicTrack>,
    val artists: List<ArtistCard>,
    val playlists: List<PlaylistCard>,
    /** Text about the artist. */
    val about: String?,
)

data class ArtistPage(
    val id: String,
    val name: String,
    val description: String?,
    val subscribers: String?,
    val thumbUrl: String?,
    val topSongs: List<MusicTrack>,
    val albums: List<AlbumCard>,
    val singles: List<AlbumCard>,
    val similar: List<ArtistCard>,
)

/** A titled row of a home page: songs, playlists, or both. */
data class MusicShelf(val title: String, val tracks: List<MusicTrack>, val playlists: List<PlaylistCard> = emptyList())

/** The part of YouTube Music this app reads; the rest of the app only knows this interface. */
interface MusicSource {
    /** The radio of [videoId] (what plays after it), or only the song itself without [radio]. */
    suspend fun watchNext(videoId: String, radio: Boolean = true): WatchNext

    suspend fun related(relatedId: String): Related

    /** The words of a song, as plain text without times; null when there are none. */
    suspend fun lyrics(lyricsId: String): String?

    suspend fun artist(artistId: String): ArtistPage

    /** Songs (audio releases) matching [query]. */
    suspend fun searchSongs(query: String): List<MusicTrack>

    /** Videos matching [query]. */
    suspend fun searchVideos(query: String): List<MusicTrack>

    /** What YouTube Music shows everybody on its home page. */
    suspend fun trending(): List<MusicShelf>
}
