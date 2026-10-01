package app.unison.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * What the full player shows about a song. Every answer is kept for a while, so going back and forth between
 * songs, or opening the same page twice, does not ask again; lyrics are kept in files.
 */
class MusicFeed(
    private val music: MusicSource,
    private val lyricsClient: LyricsClient,
    private val lyricsStore: LyricsStore,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val next = Recent<String, WatchNext>()
    private val related = Recent<String, Related>()
    private val artists = Recent<String, ArtistPage>()
    private val lyricsLock = Mutex()
    private var trendingKept: Triple<String, Long, List<MusicShelf>>? = null

    /** The radio of the song, with where its lyrics and related page are. */
    suspend fun watchNext(videoId: String): WatchNext = next.getOrPut(videoId) { music.watchNext(videoId) }

    suspend fun related(videoId: String): Related? {
        val page = watchNext(videoId).relatedId ?: return null
        return related.getOrPut(page) { music.related(page) }
    }

    suspend fun artist(artistId: String): ArtistPage = artists.getOrPut(artistId) { music.artist(artistId) }

    /** What YouTube Music shows everybody, kept for [TRENDING_MS] (and not shown in another language than it was asked in). */
    suspend fun trending(language: String = "en"): List<MusicShelf> {
        trendingKept?.let { (kept, at, shelves) -> if (kept == language && now() - at < TRENDING_MS) return shelves }
        return music.trending(language).also { trendingKept = Triple(language, now(), it) }
    }

    /** Songs matching [query], as audio releases or as videos. */
    suspend fun search(query: String, songs: Boolean): List<MusicTrack> =
        if (songs) music.searchSongs(query) else music.searchVideos(query)

    /**
     * The lyrics of a song: lyrics with times when LRCLIB has them, else the plain words YouTube Music has, else
     * null. A failed attempt (no network) is not kept, so the next look tries again.
     */
    suspend fun lyrics(videoId: String, title: String, artist: String, durationSec: Long): Lyrics? = lyricsLock.withLock {
        when (val kept = lyricsStore.get(videoId)) {
            is KeptLyrics.Found -> return@withLock kept.lyrics
            is KeptLyrics.Missing -> if (now() - kept.checkedAt < MISSING_MS) return@withLock null
            null -> Unit
        }
        val timed = lyricsClient.find(title, artist, durationSec)
        val found = if (timed?.synced == true) timed else plainFromYoutube(videoId) ?: timed
        if (found != null) lyricsStore.putFound(videoId, found) else lyricsStore.putMissing(videoId, now())
        found
    }

    private suspend fun plainFromYoutube(videoId: String): Lyrics? {
        val page = watchNext(videoId).lyricsId ?: return null
        return music.lyrics(page)?.let { Lyrics(emptyList(), it) }
    }

    /** The last few answers, oldest let go first. */
    private class Recent<K, V : Any>(private val size: Int = 24) {
        private val map = object : LinkedHashMap<K, V>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>) = this.size > size
        }

        suspend fun getOrPut(key: K, load: suspend () -> V): V {
            synchronized(map) { map[key] }?.let { return it }
            return load().also { synchronized(map) { map[key] = it } }
        }
    }

    companion object {
        /** A song without lyrics is looked up again after this long. */
        const val MISSING_MS = 7L * 24 * 60 * 60 * 1000

        /** The home page of YouTube Music changes by the hour at most. */
        const val TRENDING_MS = 6L * 60 * 60 * 1000
    }
}
