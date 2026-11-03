package app.sapoche.sync

/** Where a song that plays came from, kept beside every listen and skip so the suggestions can be judged by their source. */
object ListenSource {
    /** Picked on purpose: a search, the library, a playlist. Also what an old row without a source is taken for. */
    const val CHOSEN = "chosen"

    /** Added by autoplay or by a radio, in the personal queue or in a room. */
    const val AUTO = "auto"

    /** Started from a shelf of the home page (Quick picks, a mix, Discover...). */
    const val SHELF = "shelf"

    /** In a room, a song another member put on the queue. */
    const val ROOM_OTHER = "room_other"

    /** What a song somebody else picked says about this person's taste, next to one they picked themselves (1). */
    const val OTHER_WEIGHT = 0.5

    fun weight(source: String?) = if (source == ROOM_OTHER) OTHER_WEIGHT else 1.0
}

/**
 * Remembers which songs of the queue were put there by autoplay or from a shelf, so a listen can say where it came
 * from. A song put on the queue by hand is forgotten here, because [ListenSource.CHOSEN] is what is left. Only the
 * latest [keep] songs are kept.
 */
class ListenSources(private val keep: Int = 400) {
    private val marked = LinkedHashMap<String, String>()

    @Synchronized
    fun mark(ids: Collection<String>, source: String) {
        for (id in ids) {
            marked.remove(id)
            if (source != ListenSource.CHOSEN) marked[id] = source
        }
        while (marked.size > keep) marked.remove(marked.keys.first())
    }

    /**
     * The source of [videoId]. In a room, [item] is the queue item playing and [you] this device's public id: what
     * autoplay put there and what others put there say so themselves.
     */
    @Synchronized
    fun of(videoId: String, item: QueueItem? = null, you: String? = null): String {
        if (item != null) {
            if (item.auto) return ListenSource.AUTO
            if (you != null && item.addedBy != you) return ListenSource.ROOM_OTHER
        }
        return marked[videoId] ?: ListenSource.CHOSEN
    }
}
