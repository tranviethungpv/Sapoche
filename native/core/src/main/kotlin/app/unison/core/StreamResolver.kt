package app.unison.core

/** Minimal track metadata, enough to display a result and put it on the queue. */
data class TrackInfo(
    val videoId: String,
    val title: String,
    val artist: String,
    val thumbUrl: String?,
    val durationSec: Long,
)

/** A playlist's songs in order, without the unavailable ones. */
data class Playlist(val title: String, val tracks: List<TrackInfo>)

/** A resolved audio stream, with details used to judge quality. */
data class AudioSource(
    val url: String,
    val codec: String,
    val bitrateKbps: Int,
    val contentLength: Long,
    val itag: Int,
)

data class Resolved(
    val track: TrackInfo,
    val best: AudioSource,
    val all: List<AudioSource>,
    val resolveMs: Long,
)

/**
 * Swappable stream source: this device (NewPipeExtractor), a home host, iOS, etc.
 * The rest of the app only knows this interface.
 */
interface StreamResolver {
    suspend fun search(query: String, limit: Int = 10): List<TrackInfo>
    suspend fun resolve(videoId: String): Resolved

    /** The first [limit] playable songs of the playlist with the given id. */
    suspend fun playlist(playlistId: String, limit: Int = 50): Playlist
}
