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

    /** The most songs autoplay asks for radios of in all, its own and the members' offers together. */
    const val MAX_BLEND = 5

    /**
     * [base] (see [seeds]) with one song of each member's offer, to look for songs that suit the room and not only the
     * last song: [offers] are the video ids each member offered, in the order they gave them. Which song of an offer, and
     * which members when there are not places for all, goes round with [epoch], so the next time the room runs out it is
     * others'. Songs already among the seeds are not taken twice. At most [max] come back in all.
     */
    fun blend(base: List<String>, offers: List<List<String>>, epoch: Long, max: Int = MAX_BLEND): List<String> {
        val result = ArrayList(base)
        val members = offers.filter { it.isNotEmpty() }
        if (members.isEmpty()) return result
        val start = Math.floorMod(epoch, members.size.toLong()).toInt()
        for (i in members.indices) {
            if (result.size >= max) break
            val offer = members[(start + i) % members.size]
            val pick = (0 until offer.size).map { offer[Math.floorMod(epoch + it, offer.size.toLong()).toInt()] }.firstOrNull { it !in result } ?: continue
            result += pick
        }
        return result
    }
}
