package app.unison

import app.unison.core.MusicFeed
import app.unison.core.StreamResolver
import app.unison.sync.Blocklist
import app.unison.sync.Stamped
import app.unison.sync.Suggestions
import app.unison.sync.Taste
import app.unison.sync.TrackRef
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * What to offer to play. YouTube lists related songs beside any song, so suggestions come from a few songs the
 * person loves most (the seeds, chosen by [Taste] from what they heard, liked and left after a few seconds). The
 * lists are kept for [FRESH_MS], so opening the app shows them at once, even offline, and the network is only used
 * to renew them.
 */
class SuggestionFeed(
    private val store: LibraryStore,
    private val resolver: StreamResolver,
    private val music: MusicFeed,
    private val now: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    private val renewing = Mutex()

    /** What the library says about the person, as of now. */
    private suspend fun taste(): Taste = Taste(
        heard = store.listens().map { Stamped(it.track, it.at) },
        liked = store.liked().map { Stamped(it.track, it.at) },
        skipped = store.skipped().map { Stamped(it.track, it.at) },
        now = now(),
    )

    private suspend fun blocklist(): Blocklist {
        val blocked = store.blocked()
        return Blocklist(
            songs = blocked.filter { it.kind == SONG }.map { it.key }.toSet(),
            artists = blocked.filter { it.kind == ARTIST }.map { it.key }.toSet(),
        )
    }

    /** The lists kept for [seeds], the best loved seed first; a seed without a list is left out. */
    private suspend fun kept(seeds: List<String>) = seeds.mapNotNull { store.cachedSuggestions(it)?.tracks }

    /** Songs to offer, from what is kept; nothing until there are seeds and their lists were fetched once. */
    suspend fun forYou(limit: Int = FOR_YOU): List<TrackRef> {
        val taste = taste()
        val block = blocklist()
        val seeds = taste.seeds(SEEDS, block)
        return Suggestions.compose(kept(seeds), taste, block, known(seeds), limit)
    }

    /** Songs by artists the person does not know yet, from what is kept: something new to try. */
    suspend fun discover(limit: Int = DISCOVER): List<TrackRef> {
        val taste = taste()
        val block = blocklist()
        val seeds = taste.seeds(SEEDS, block)
        return Suggestions.discover(kept(seeds), taste, block, known(seeds), limit)
    }

    /**
     * Fetches again the lists of the seeds whose list is missing or older than [FRESH_MS], or all of them with
     * [force]. One failed seed does not stop the others; what was kept for it stays. Returns whether anything changed.
     */
    suspend fun renew(force: Boolean): Boolean = renewing.withLock {
        val taste = taste()
        val block = blocklist()
        val seeds = taste.seeds(SEEDS, block)
        var changed = false
        for (seed in seeds) {
            if (fetch(seed, force)) changed = true
        }
        // The lists behind the mixes for each time of day stay too, so they are there when that time comes
        store.keepSuggestionsFor(seeds + Taste.BUCKETS.flatMap { bucket -> taste.contextSeeds(bucket, block).map { it.videoId } })
        changed
    }

    /** Fetches the radio of [seed] and keeps it, unless a fresh one is kept (and not [force]d). False when nothing changed. */
    private suspend fun fetch(seed: String, force: Boolean): Boolean {
        val kept = store.cachedSuggestions(seed)
        if (!force && kept != null && now() - kept.fetchedAt < FRESH_MS) return false
        return try {
            store.putSuggestions(seed, radioOf(seed).filter(Suggestions::isSong), now())
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log("could not fetch suggestions for $seed: ${e.javaClass.simpleName}: ${e.message}")
            false
        }
    }

    /** The songs kept for each seed, for the screens that say "because you listened to". */
    suspend fun seedLists(): List<Pair<String, List<TrackRef>>> {
        val seeds = taste().seeds(SEEDS, blocklist())
        return seeds.mapNotNull { seed -> store.cachedSuggestions(seed)?.let { seed to it.tracks } }
    }

    /**
     * A mix for this time of day: the songs the person plays at this hour, then what YouTube lists beside them. The
     * part of the day and the songs, empty until enough was heard at this hour to say anything. A list that was
     * not kept yet is fetched, so this may need the network.
     */
    suspend fun contextMix(limit: Int = CONTEXT): Pair<String, List<TrackRef>> {
        val taste = taste()
        val block = blocklist()
        val bucket = Taste.bucketOf(java.util.Calendar.getInstance().apply { timeInMillis = now() }.get(java.util.Calendar.HOUR_OF_DAY))
        val seeds = taste.contextSeeds(bucket, block)
        if (seeds.isEmpty()) return bucket to emptyList()
        for (seed in seeds) fetch(seed.videoId, force = false)
        val ids = seeds.map { it.videoId }.toSet()
        val songs = seeds + Suggestions.compose(kept(ids.toList()), taste, block, ids, limit)
        return bucket to songs.take(limit)
    }

    /**
     * Up to [count] songs to carry on with after [videoId], other than [exclude], what was heard lately and what the
     * person does not want: the radio YouTube Music makes of the song, or what YouTube lists beside it when that
     * cannot be had. Needs the network.
     */
    suspend fun after(videoId: String, exclude: Set<String>, count: Int): List<TrackRef> {
        val taste = taste()
        val block = blocklist()
        return Suggestions.mix(
            listOf(radioOf(videoId)),
            exclude + videoId + store.heardSince(now() - RECENT_MS),
            count,
        ) { Suggestions.welcome(it, taste, block) }
    }

    /** The radio YouTube Music makes of the song, or what YouTube lists beside it when that cannot be had. */
    private suspend fun radioOf(videoId: String): List<TrackRef> {
        val radio = try {
            music.watchNext(videoId).tracks.map { TrackRef(it.videoId, it.title, it.artist, it.thumbUrl, it.durationSec * 1000) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log("no radio for $videoId, using the related list: ${e.javaClass.simpleName}: ${e.message}")
            emptyList()
        }
        return radio.ifEmpty {
            resolver.related(videoId).map { TrackRef(it.videoId, it.title, it.artist, it.thumbUrl, it.durationSec * 1000) }
        }
    }

    /** Songs not worth offering: the seeds themselves, those liked and those heard this week. */
    private suspend fun known(seeds: List<String>): Set<String> = seeds.toSet() + store.likedIds() + store.heardSince(now() - RECENT_MS)

    companion object {
        const val FOR_YOU = 30
        const val DISCOVER = 20
        const val CONTEXT = 20
        const val SEEDS = 5
        const val FRESH_MS = 12L * 60 * 60 * 1000
        const val SONG = "song"
        const val ARTIST = "artist"
        private const val RECENT_MS = 7L * 24 * 60 * 60 * 1000
    }
}
