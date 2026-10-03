package app.sapoche.core

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
    /** What YouTube says about a video's reach, like "1.8B views · 19M likes"; null for a song. */
    val stats: String? = null,
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

/**
 * An artist, or a profile (somebody who is not an artist but puts videos and playlists up). [shelves] are the other
 * rows of the page (videos, live performances, playlists); [topSongsId] is the playlist that holds all of the top songs.
 */
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
    val shelves: List<MusicShelf> = emptyList(),
    val topSongsId: String? = null,
)

/** A titled row of a page: songs, albums, playlists or artists, any mix of them. */
data class MusicShelf(
    val title: String,
    val tracks: List<MusicTrack>,
    val playlists: List<PlaylistCard> = emptyList(),
    val albums: List<AlbumCard> = emptyList(),
    val artists: List<ArtistCard> = emptyList(),
)

/**
 * An album, single, EP or playlist: what it is, who made it and its songs. [more] is where the songs after these are
 * asked for (a long playlist comes a hundred at a time); null when these are all of them.
 */
data class CollectionPage(
    val id: String,
    val title: String,
    /** What YouTube calls it: "Album", "Single", "EP", "Playlist". */
    val kind: String?,
    val year: String?,
    /** The artist of an album, or who made the playlist, and where their page is when there is one. */
    val owner: String?,
    val ownerId: String?,
    val description: String?,
    val thumbUrl: String?,
    /** The facts under the title, like "18 songs" and "1 hour, 13 minutes". */
    val stats: List<String>,
    val tracks: List<MusicTrack>,
    val more: String?,
    /** Other rows of the page: more by the artist, similar playlists. */
    val shelves: List<MusicShelf>,
)

/**
 * One result of a search. [kind] is `song`, `video`, `episode`, `album` (an album, single or EP), `artist`, `profile`
 * or `playlist` (a playlist or a podcast); [id] is the video to play or the page to open. [label] is what YouTube
 * calls it when it says so ("Single", "EP"). [track] is there for what plays: song, video and episode.
 */
data class SearchItem(
    val kind: String,
    val id: String,
    val title: String,
    val subtitle: String?,
    val label: String?,
    val thumbUrl: String?,
    val track: MusicTrack? = null,
)

/** A filter YouTube Music offers for a search, and the code that asks for it. */
data class SearchChip(val label: String, val params: String)

/**
 * What a search found: the [top] result when YouTube picks one, the [items] in the order it lists them, and the
 * [chips] to narrow it down. [more] is where the results after these are asked for; null when these are all.
 */
data class SearchPage(val chips: List<SearchChip>, val top: SearchItem?, val items: List<SearchItem>, val more: String?)

/** The songs after those of a [CollectionPage]. */
data class Continuation(val tracks: List<MusicTrack>, val more: String?)

/** The part of YouTube Music this app reads; the rest of the app only knows this interface. */
interface MusicSource {
    /** The radio of [videoId] (what plays after it), or only the song itself without [radio]. */
    suspend fun watchNext(videoId: String, radio: Boolean = true): WatchNext

    suspend fun related(relatedId: String): Related

    /** The words of a song, as plain text without times; null when there are none. */
    suspend fun lyrics(lyricsId: String): String?

    suspend fun artist(artistId: String): ArtistPage

    /** An album or a playlist, by the id of its page (`MPRE…` for an album, a playlist id otherwise). */
    suspend fun collection(id: String): CollectionPage

    /** The songs of a long playlist after [token], which an earlier answer gave. */
    suspend fun more(token: String): Continuation

    /** Everything that matches [query], or what a filter of [SearchChip.params] keeps of it. */
    suspend fun searchPage(query: String, params: String?): SearchPage

    /** The results of a search after [token], which an earlier answer gave. */
    suspend fun searchMore(token: String): SearchPage

    /** Songs (audio releases) matching [query]. */
    suspend fun searchSongs(query: String): List<MusicTrack>

    /** Videos matching [query]. */
    suspend fun searchVideos(query: String): List<MusicTrack>

    /** What YouTube Music shows everybody on its home page, with the shelf names in [language] (a code like "vi"). */
    suspend fun trending(language: String = "en"): List<MusicShelf>
}
