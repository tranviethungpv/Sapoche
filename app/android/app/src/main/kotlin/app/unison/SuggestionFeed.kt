package app.unison

import app.unison.core.MusicFeed
import app.unison.core.StreamResolver
import app.unison.sync.Suggestions
import app.unison.sync.TrackRef
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * What to offer to play. YouTube lists related songs beside any song, so suggestions come from a few songs the
 * person likes or plays a lot (the seeds). The lists are kept for [FRESH_MS], so opening the app shows them at
 * once, even offline, and the network is only used to renew them.
 */
class SuggestionFeed(
    private val store: LibraryStore,
    private val resolver: StreamResolver,
    private val music: MusicFeed,
    private val now: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    private val renewing = Mutex()

    /** Songs to offer, from what is kept; nothing until there are seeds and their lists were fetched once. */
    suspend fun forYou(limit: Int = FOR_YOU): List<TrackRef> {
        val seeds = store.suggestionSeeds(now())
        val lists = seeds.mapNotNull { store.cachedSuggestions(it)?.tracks }
        return Suggestions.mix(lists, known(seeds), limit)
    }

    /**
     * Fetches again the lists of the seeds whose list is missing or older than [FRESH_MS], or all of them with
     * [force]. One failed seed does not stop the others; what was kept for it stays. Returns whether anything changed.
     */
    suspend fun renew(force: Boolean): Boolean = renewing.withLock {
        val seeds = store.suggestionSeeds(now())
        var changed = false
        for (seed in seeds) {
            val kept = store.cachedSuggestions(seed)
            if (!force && kept != null && now() - kept.fetchedAt < FRESH_MS) continue
            try {
                val songs = resolver.related(seed).map { TrackRef(it.videoId, it.title, it.artist, it.thumbUrl, it.durationSec * 1000) }
                store.putSuggestions(seed, songs.filter(Suggestions::isSong), now())
                changed = true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("could not fetch suggestions for $seed: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
        store.keepSuggestionsFor(seeds)
        changed
    }

    /**
     * Up to [count] songs to carry on with after [videoId], other than [exclude] and what was heard lately: the radio
     * YouTube Music makes of the song, or what YouTube lists beside it when that cannot be had. Needs the network.
     */
    suspend fun after(videoId: String, exclude: Set<String>, count: Int): List<TrackRef> {
        val radio = try {
            music.watchNext(videoId).tracks.map { TrackRef(it.videoId, it.title, it.artist, it.thumbUrl, it.durationSec * 1000) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log("no radio for $videoId, using the related list: ${e.javaClass.simpleName}: ${e.message}")
            emptyList()
        }
        val songs = radio.ifEmpty {
            resolver.related(videoId).map { TrackRef(it.videoId, it.title, it.artist, it.thumbUrl, it.durationSec * 1000) }
        }
        return Suggestions.mix(listOf(songs), exclude + videoId + store.heardSince(now() - RECENT_MS), count)
    }

    /** Songs not worth offering: the seeds themselves, those liked and those heard this week. */
    private suspend fun known(seeds: List<String>): Set<String> = seeds.toSet() + store.likedIds() + store.heardSince(now() - RECENT_MS)

    companion object {
        const val FOR_YOU = 30
        const val FRESH_MS = 12L * 60 * 60 * 1000
        private const val RECENT_MS = 7L * 24 * 60 * 60 * 1000
    }
}
