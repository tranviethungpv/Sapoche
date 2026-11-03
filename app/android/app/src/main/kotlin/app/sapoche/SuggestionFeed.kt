package app.sapoche

import app.sapoche.core.MusicFeed
import app.sapoche.core.StreamResolver
import app.sapoche.sync.ArtistScore
import app.sapoche.sync.Blocklist
import app.sapoche.sync.ListenSource
import app.sapoche.sync.Stamped
import app.sapoche.sync.Suggestions
import app.sapoche.sync.Taste
import app.sapoche.sync.TasteMarks
import app.sapoche.sync.TrackRef
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
    private suspend fun taste(): Taste {
        val marks = store.tasteMarks()
        return Taste(
            // The songs a new person started with count as heard when they were chosen
            heard = store.listens().map { Stamped(it.track, it.at, ListenSource.weight(it.source)) } +
                marks.filter { it.kind == TasteMarks.STARTER }.mapNotNull { TasteMarks.starter(it.label, it.at) },
            liked = store.liked().map { Stamped(it.track, it.at) },
            skipped = store.skipped().map { Stamped(it.track, it.at, ListenSource.weight(it.source)) },
            now = now(),
            quietSongs = marks.filter { it.kind == TasteMarks.QUIET_SONG }.map { it.key }.toSet(),
            quietArtists = marks.filter { it.kind == TasteMarks.QUIET_ARTIST }.map { it.key }.toSet(),
        )
    }

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

    /** The songs this person offers a room's autoplay to start from; never a song of a file, of an artist they asked for less of, or a song they asked not to count. */
    suspend fun offer(): List<TrackRef> = taste().offer(OFFER, blocklist())

    /** What the listening says about the person: how much each artist and each song is loved, and how each source fared. */
    suspend fun profile(): Profile {
        val taste = taste()
        return Profile(taste.artistScores(), taste.songScores(), store.tasteMarks(), sourceStats())
    }

    data class Profile(
        val artists: List<ArtistScore>,
        val songs: Map<String, Double>,
        val marks: List<LibraryStore.TasteMark>,
        val stats: List<LibraryStore.SourceStats>,
    )

    /** How the songs of each source fared in the last [STATS_MS]: heard, and left after a few seconds. */
    suspend fun sourceStats(): List<LibraryStore.SourceStats> = store.sourceStats(now() - STATS_MS)

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
    suspend fun after(videoId: String, exclude: Set<String>, count: Int): List<TrackRef> = afterMany(listOf(videoId), exclude, count)

    /**
     * Up to [count] songs to carry on with after the [seeds] together, as [after] does for one: the radio of each seed,
     * taken in turns so no seed crowds out the others. A seed whose radio cannot be had is left out, so the others
     * still count.
     */
    suspend fun afterMany(seeds: List<String>, exclude: Set<String>, count: Int): List<TrackRef> {
        val taste = taste()
        val block = blocklist()
        val lists = seeds.mapIndexedNotNull { i, seed ->
            try {
                radioOf(seed)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The first seed is the one asked for: with nothing for it the caller says so
                if (i == 0 && seeds.size == 1) throw e
                log("no radio for $seed: ${e.javaClass.simpleName}: ${e.message}")
                null
            }
        }
        val pool = Suggestions.mix(
            lists,
            exclude + seeds + store.heardSince(now() - RECENT_MS),
            count * POOL_FACTOR,
        ) { Suggestions.welcome(it, taste, block) }
        // YouTube's order, put in the order that suits this person
        return Suggestions.rank(pool, taste).take(count)
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
        const val OFFER = 5
        const val FOR_YOU = 30
        const val DISCOVER = 20
        const val CONTEXT = 20
        const val SEEDS = 8
        const val FRESH_MS = 12L * 60 * 60 * 1000
        const val SONG = "song"
        const val ARTIST = "artist"
        /** Songs looked at for each one that is given, so ranking has a choice. */
        private const val POOL_FACTOR = 4
        const val STATS_MS = 30L * 24 * 60 * 60 * 1000
        private const val RECENT_MS = 7L * 24 * 60 * 60 * 1000
    }
}
