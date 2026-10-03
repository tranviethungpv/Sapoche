package app.sapoche.sync

import java.util.Calendar
import kotlin.math.pow

/** A song with the moment something happened to it: it was heard, liked or left after a few seconds. */
data class Stamped(val track: TrackRef, val at: Long)

/** Songs and artists the person asked not to be offered, by video id and by [Taste.artistKey]. */
class Blocklist(private val songs: Set<String> = emptySet(), private val artists: Set<String> = emptySet()) {
    fun allows(track: TrackRef) = track.videoId !in songs && Taste.artistKey(track.artist) !in artists
}

/**
 * What the listening says about a person's taste: how much each song and each artist is loved, from what was heard
 * (a point each), liked (more) and left after a few seconds (less than nothing), all counting for less as they get
 * older. Nothing leaves the phone and nothing needs the network; it only reads what the library keeps.
 */
class Taste(
    private val heard: List<Stamped>,
    liked: List<Stamped>,
    skipped: List<Stamped>,
    private val now: Long,
    private val hourOf: (Long) -> Int = ::localHour,
) {
    private val songs = HashMap<String, Double>()
    private val artists = HashMap<String, Double>()
    private val tracks = HashMap<String, TrackRef>()

    init {
        fun add(list: List<Stamped>, weight: Double, halfLifeMs: Long) {
            for (s in list) {
                val value = weight * decay(now - s.at, halfLifeMs)
                songs.merge(s.track.videoId, value, Double::plus)
                artists.merge(artistKey(s.track.artist), value, Double::plus)
                tracks.putIfAbsent(s.track.videoId, s.track)
            }
        }
        add(heard, HEARD, PLAY_HALF_LIFE_MS)
        add(liked, LIKED, LIKE_HALF_LIFE_MS)
        add(skipped, SKIPPED, PLAY_HALF_LIFE_MS)
    }

    /** The artist has been listened to, or liked, enough to be known. */
    fun knows(artist: String) = (artists[artistKey(artist)] ?: 0.0) >= KNOWN

    /** The artist's songs were left lately more than they were heard. */
    fun dislikes(artist: String) = (artists[artistKey(artist)] ?: 0.0) <= DISLIKED

    /**
     * The songs suggestions are built from, up to [count]: the best loved, one per artist where there are enough
     * artists, so the mix is not all one voice. A song of an artist that is disliked or blocked is never one.
     */
    fun seeds(count: Int, block: Blocklist = Blocklist()): List<String> {
        val ranked = songs.entries
            .filter { it.value >= MIN_SEED }
            .mapNotNull { e -> tracks[e.key]?.takeIf { block.allows(it) && !dislikes(it.artist) }?.let { it to e.value } }
            .sortedWith(compareByDescending<Pair<TrackRef, Double>> { it.second }.thenBy { it.first.videoId })
            .map { it.first }
        val picked = LinkedHashMap<String, TrackRef>()
        val perArtist = HashMap<String, Int>()
        for (cap in 1..2) {
            for (track in ranked) {
                if (picked.size >= count) break
                val key = artistKey(track.artist)
                if (track.videoId in picked || (perArtist[key] ?: 0) >= cap) continue
                picked[track.videoId] = track
                perArtist.merge(key, 1, Int::plus)
            }
        }
        return picked.keys.toList()
    }

    /**
     * The songs the person plays at this time of day ([bucket], see [bucketOf]), most played first, up to [count], one
     * per artist; empty until enough was heard at that time for it to mean something.
     */
    fun contextSeeds(bucket: String, block: Blocklist = Blocklist(), count: Int = 2): List<TrackRef> {
        val since = now - CONTEXT_WINDOW_MS
        val inBucket = heard.filter { it.at >= since && bucketOf(hourOf(it.at)) == bucket }
        if (inBucket.size < MIN_CONTEXT) return emptyList()
        val plays = HashMap<String, Double>()
        val seen = HashMap<String, TrackRef>()
        for (s in inBucket) {
            plays.merge(s.track.videoId, decay(now - s.at, PLAY_HALF_LIFE_MS), Double::plus)
            seen.putIfAbsent(s.track.videoId, s.track)
        }
        val picked = ArrayList<TrackRef>()
        val artistsTaken = HashSet<String>()
        for (id in plays.keys.sortedWith(compareByDescending<String> { plays[it] }.thenBy { it })) {
            val track = seen.getValue(id)
            if (picked.size >= count) break
            if (!block.allows(track) || (songs[id] ?: 0.0) <= 0.0 || !artistsTaken.add(artistKey(track.artist))) continue
            picked += track
        }
        return picked
    }

    companion object {
        const val HEARD = 1.0
        const val LIKED = 2.5
        const val SKIPPED = -1.2
        const val PLAY_HALF_LIFE_MS = 21L * 24 * 60 * 60 * 1000
        const val LIKE_HALF_LIFE_MS = 90L * 24 * 60 * 60 * 1000
        const val KNOWN = 0.5
        const val DISLIKED = -2.0
        const val MIN_SEED = 0.5
        const val CONTEXT_WINDOW_MS = 60L * 24 * 60 * 60 * 1000
        const val MIN_CONTEXT = 5

        /** The parts of a day, for the mix that suits the time: morning, afternoon, evening and night. */
        val BUCKETS = listOf("morning", "afternoon", "evening", "night")

        fun bucketOf(hour: Int) = when (hour) {
            in 5..10 -> "morning"
            in 11..16 -> "afternoon"
            in 17..21 -> "evening"
            else -> "night"
        }

        private fun decay(ageMs: Long, halfLifeMs: Long) = 0.5.pow(ageMs.coerceAtLeast(0).toDouble() / halfLifeMs)

        private fun localHour(at: Long) = Calendar.getInstance().apply { timeInMillis = at }.get(Calendar.HOUR_OF_DAY)

        private val CHANNEL_SUFFIX = Regex("""\s*(?:-\s*topic|vevo|official(?:\s+channel)?)$""", RegexOption.IGNORE_CASE)
        private val ARTIST_SPLIT = Regex("""\s*(?:,|&|\bx\b|\bfeat\.?|\bft\.?|\bvà\b|\band\b)\s*""", RegexOption.IGNORE_CASE)
        private val PUNCTUATION = Regex("""[^\p{L}\p{N}]+""")

        /** The first artist of a credit like "A, B & C" as it is written, without "- Topic", "VEVO" or "Official". */
        fun artistLabel(credit: String): String {
            val first = ARTIST_SPLIT.split(CHANNEL_SUFFIX.replace(credit.trim(), "")).first()
            return CHANNEL_SUFFIX.replace(first, "").trim()
        }

        /** What tells one artist from another: the first artist of a credit in plain lower-case letters (as the UI does). */
        fun artistKey(credit: String) = PUNCTUATION.replace(artistLabel(credit).lowercase(), " ").trim()
    }
}
