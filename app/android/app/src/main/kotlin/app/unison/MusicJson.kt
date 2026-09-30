package app.unison

import app.unison.core.AlbumCard
import app.unison.core.ArtistCard
import app.unison.core.ArtistPage
import app.unison.core.Lyrics
import app.unison.core.MusicShelf
import app.unison.core.MusicTrack
import app.unison.core.PlaylistCard
import app.unison.core.Related
import app.unison.core.WatchNext

/** What the full player shows, in the shape the UI reads it (plain maps for the platform channel). */
object MusicJson {

    fun track(track: MusicTrack): Map<String, Any?> = mapOf(
        "videoId" to track.videoId,
        "title" to track.title,
        "artist" to track.artist,
        "artistId" to track.artistId,
        "album" to track.album,
        "albumId" to track.albumId,
        "year" to track.year,
        "thumb" to track.thumbUrl,
        "durMs" to track.durationSec * 1000,
        "isSong" to track.isSong,
        "stats" to track.stats,
    )

    fun next(next: WatchNext): Map<String, Any?> = mapOf(
        "tracks" to next.tracks.map(::track),
        "hasLyrics" to (next.lyricsId != null),
        "hasRelated" to (next.relatedId != null),
    )

    fun related(related: Related?): Map<String, Any?> = mapOf(
        "more" to related?.more.orEmpty().map(::track),
        "otherPerformances" to related?.otherPerformances.orEmpty().map(::track),
        "artists" to related?.artists.orEmpty().map(::artistCard),
        "playlists" to related?.playlists.orEmpty().map(::playlistCard),
        "about" to related?.about,
    )

    fun artist(page: ArtistPage): Map<String, Any?> = mapOf(
        "id" to page.id,
        "name" to page.name,
        "description" to page.description,
        "subscribers" to page.subscribers,
        "thumb" to page.thumbUrl,
        "topSongs" to page.topSongs.map(::track),
        "albums" to page.albums.map(::albumCard),
        "singles" to page.singles.map(::albumCard),
        "similar" to page.similar.map(::artistCard),
    )

    /** Times in whole milliseconds, one pair per line; with no times the lines are empty and only the plain text is there. */
    fun lyrics(lyrics: Lyrics?): Map<String, Any?>? = lyrics?.let {
        mapOf(
            "synced" to it.synced,
            "lines" to it.lines.map { line -> listOf(line.ms, line.text) },
            "plain" to it.plain,
        )
    }

    fun shelves(shelves: List<MusicShelf>): List<Map<String, Any?>> = shelves.map {
        mapOf("title" to it.title, "tracks" to it.tracks.map(::track), "playlists" to it.playlists.map(::playlistCard))
    }

    private fun artistCard(card: ArtistCard) = mapOf("id" to card.id, "name" to card.name, "subtitle" to card.subtitle, "thumb" to card.thumbUrl)

    private fun albumCard(card: AlbumCard) = mapOf("id" to card.id, "title" to card.title, "subtitle" to card.subtitle, "thumb" to card.thumbUrl)

    private fun playlistCard(card: PlaylistCard) = mapOf("id" to card.id, "title" to card.title, "subtitle" to card.subtitle, "thumb" to card.thumbUrl)
}
