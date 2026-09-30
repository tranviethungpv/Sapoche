package app.unison.sync

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
     * in [exclude], repeats and non-songs are dropped. At most [limit] come back.
     */
    fun mix(lists: List<List<TrackRef>>, exclude: Set<String>, limit: Int): List<TrackRef> {
        val seen = HashSet(exclude)
        val result = ArrayList<TrackRef>()
        val queues = lists.map { list -> list.filter(::isSong).iterator() }
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
}
