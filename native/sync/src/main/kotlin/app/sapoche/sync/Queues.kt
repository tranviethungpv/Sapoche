package app.sapoche.sync

object Queues {
    /**
     * The songs of [tracks] worth adding to [queue], whose song at [index] is the one playing: those not
     * already waiting in it (playing now or still to come) and not repeated within [tracks]. A song that was
     * played already may be added again, and so may one that autoplay lined up: the room takes that one off.
     */
    fun fresh(tracks: List<TrackRef>, queue: List<QueueItem>, index: Int): List<TrackRef> {
        val seen = queue.drop(index.coerceAtLeast(0)).filterIndexed { i, item -> i == 0 || !item.auto }.mapTo(HashSet()) { it.videoId }
        return tracks.filter { seen.add(it.videoId) }
    }

    /** The most songs autoplay asks a radio for at once: more would be many requests for a room that has run dry. */
    const val MAX_SEEDS = 3

    /**
     * The songs a room's autoplay looks for more of: [ask], the last song, then the songs of [queue] that members put there,
     * the latest first, one for each member who has not a song among them yet. Songs autoplay itself put there are not
     * a member's choice and are left out. A room where one member added everything gives [ask] alone, as it always did.
     */
    fun seeds(queue: List<QueueItem>, ask: String, max: Int = MAX_SEEDS): List<String> {
        val seeds = arrayListOf(ask)
        val adders = HashSet<String>()
        queue.lastOrNull { it.videoId == ask && !it.auto }?.let { adders += it.addedBy }
        for (item in queue.asReversed()) {
            if (seeds.size >= max) break
            if (item.auto || item.videoId in seeds || !adders.add(item.addedBy)) continue
            seeds += item.videoId
        }
        return seeds
    }
}
