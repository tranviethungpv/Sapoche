package app.sapoche.sync

/**
 * Turns the songs YouTube lists beside a few seed songs into one list worth offering. YouTube's related
 * lists hold hour-long mixes and full albums beside songs, and songs the person already knows.
 */
object Suggestions {
    /** Songs shorter or longer than this are left out: what is left is mostly music. */
    const val MIN_MS = 60_000L
    const val MAX_MS = 600_000L

    fun isSong(track: TrackRef) = track.durMs in MIN_MS..MAX_MS

    /**
     * One list from several [lists], taking a song from each in turn so no seed crowds out the others. Songs
     * in [exclude], repeats, non-songs and what [allow] refuses are dropped. At most [limit] come back.
     */
    fun mix(
        lists: List<List<TrackRef>>,
        exclude: Set<String>,
        limit: Int,
        allow: (TrackRef) -> Boolean = { true },
    ): List<TrackRef> {
        val seen = HashSet(exclude)
        val result = ArrayList<TrackRef>()
        val queues = lists.map { list -> list.filter { isSong(it) && allow(it) }.iterator() }
        while (result.size < limit && queues.any { it.hasNext() }) {
            for (queue in queues) {
                while (queue.hasNext()) {
                    val track = queue.next()
                    if (!seen.add(track.videoId)) continue
                    result += track
                    break
                }
                if (result.size >= limit) break
            }
        }
        return result
    }

    /** At most this many songs of one artist in a list of suggestions. */
    const val MAX_PER_ARTIST = 2

    /** Of every ten songs, these come from artists the person does not know yet (the rest from ones they do). */
    private val NEW_ARTIST_SLOTS = setOf(2, 5, 8)

    /** What the person should be offered, or nothing from artists they asked not to hear or left again and again. */
    fun welcome(track: TrackRef, taste: Taste, block: Blocklist) = isSong(track) && block.allows(track) && !taste.dislikes(track.artist)

    /**
     * The suggestions of the seeds ([lists], best loved seed first) as one list: songs by artists the person knows, with a
     * few by artists they do not know in between, so the list is mostly what they like and a little of what they
     * might. Songs in [exclude] and what is not [welcome] are left out, and no artist comes more than [MAX_PER_ARTIST]
     * times. At most [limit] come back.
     */
    fun compose(lists: List<List<TrackRef>>, taste: Taste, block: Blocklist, exclude: Set<String>, limit: Int): List<TrackRef> {
        val welcome = lists.map { list -> list.filter { welcome(it, taste, block) } }
        val known = ArrayDeque(turns(welcome.map { list -> list.filter { taste.knows(it.artist) } }))
        val fresh = ArrayDeque(turns(welcome.map { list -> list.filterNot { taste.knows(it.artist) } }))
        val seen = HashSet(exclude)
        val perArtist = HashMap<String, Int>()
        fun take(queue: ArrayDeque<TrackRef>): TrackRef? {
            while (queue.isNotEmpty()) {
                val track = queue.removeFirst()
                val artist = Taste.artistKey(track.artist)
                if (track.videoId in seen || (perArtist[artist] ?: 0) >= MAX_PER_ARTIST) continue
                seen += track.videoId
                perArtist.merge(artist, 1, Int::plus)
                return track
            }
            return null
        }
        val result = ArrayList<TrackRef>()
        while (result.size < limit) {
            val wantFresh = result.size % 10 in NEW_ARTIST_SLOTS
            val track = (if (wantFresh) take(fresh) ?: take(known) else take(known) ?: take(fresh)) ?: break
            result += track
        }
        return result
    }

    /** Only the songs by artists the person does not know yet, a few of each artist: something new to try. */
    fun discover(lists: List<List<TrackRef>>, taste: Taste, block: Blocklist, exclude: Set<String>, limit: Int): List<TrackRef> {
        val fresh = lists.map { list -> list.filter { welcome(it, taste, block) && !taste.knows(it.artist) } }
        val seen = HashSet(exclude)
        val artists = HashSet<String>()
        return turns(fresh).filter { seen.add(it.videoId) && artists.add(Taste.artistKey(it.artist)) }.take(limit)
    }

    /** Of every five songs, the last is for an artist the person does not know yet. */
    private const val STRANGER_EVERY = 5

    /** Position counts for less the further down the radio's list a song stands: half as much at the eighth place. */
    private const val POSITION_SPAN = 8.0

    /** How much knowing the artist adds to a song's score, as a share of the artist loved most. */
    private const val AFFINITY_WEIGHT = 0.35

    /**
     * [list], a radio's songs in the order YouTube gives them, put in the order that suits this person: the nearer the top
     * the better, plus a little for songs by artists they love. A song they left more than they heard is dropped, every
     * fifth place is kept for an artist they do not know yet if the list has one, and no artist comes more than
     * [MAX_PER_ARTIST] times. The order is the same whenever the same list and the same taste are given.
     */
    fun rank(list: List<TrackRef>, taste: Taste): List<TrackRef> {
        val strongest = taste.strongestArtist
        fun affinity(track: TrackRef) = if (strongest <= 0) 0.0 else (taste.artistScore(track.artist) / strongest).coerceIn(0.0, 1.0)
        val ordered = list.withIndex()
            .filter { taste.songScore(it.value.videoId) >= 0 }
            .sortedWith(compareByDescending<IndexedValue<TrackRef>> { 1.0 / (1 + it.index / POSITION_SPAN) + AFFINITY_WEIGHT * affinity(it.value) }.thenBy { it.index })
            .map { it.value }
        val taken = HashSet<String>()
        val perArtist = HashMap<String, Int>()
        val result = ArrayList<TrackRef>()
        fun fits(track: TrackRef) = track.videoId !in taken && (perArtist[Taste.artistKey(track.artist)] ?: 0) < MAX_PER_ARTIST
        while (true) {
            val stranger = result.size % STRANGER_EVERY == STRANGER_EVERY - 1
            val next = (if (stranger) ordered.firstOrNull { fits(it) && !taste.knows(it.artist) } else null) ?: ordered.firstOrNull(::fits) ?: break
            taken += next.videoId
            perArtist.merge(Taste.artistKey(next.artist), 1, Int::plus)
            result += next
        }
        return result
    }

    /** The lists read in turns, one song from each at a time. */
    private fun turns(lists: List<List<TrackRef>>): List<TrackRef> {
        val queues = lists.map { it.iterator() }
        val result = ArrayList<TrackRef>()
        while (queues.any { it.hasNext() }) {
            for (queue in queues) if (queue.hasNext()) result += queue.next()
        }
        return result
    }
}
