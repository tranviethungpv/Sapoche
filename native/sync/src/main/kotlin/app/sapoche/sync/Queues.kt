package app.sapoche.sync

object Queues {
    /**
     * The songs of [tracks] worth adding to [queue], whose song at [index] is the one playing: those not
     * already waiting in it (playing now or still to come) and not repeated within [tracks]. A song that was
     * played already may be added again.
     */
    fun fresh(tracks: List<TrackRef>, queue: List<QueueItem>, index: Int): List<TrackRef> {
        val seen = queue.drop(index.coerceAtLeast(0)).mapTo(HashSet()) { it.videoId }
        return tracks.filter { seen.add(it.videoId) }
    }
}
