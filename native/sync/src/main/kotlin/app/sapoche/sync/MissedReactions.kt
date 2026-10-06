package app.sapoche.sync

/**
 * The reactions that came while nobody looked at the screen, for the screen that comes back. The room keeps no
 * reaction, so what this device heard while it lay in a pocket is all there is of them. Only the last [KEEP_MS] count:
 * a heart from an hour ago is no longer a reaction to anything.
 *
 * [now] is a clock that keeps counting while the device sleeps (`SystemClock.elapsedRealtime`).
 */
class MissedReactions(private val now: () -> Long) {
    /** [n] taps of [e] by member [by]. */
    data class Missed(val by: String, val e: String, val n: Int)

    private class Entry(val by: String, val e: String, val n: Int, val at: Long)

    private val entries = ArrayDeque<Entry>()

    fun add(by: String, e: String, n: Int) {
        entries.addLast(Entry(by, e, n, now()))
        while (entries.size > MAX_ENTRIES) entries.removeFirst()
    }

    /** What is still worth showing, the taps of each member on each emoji added up in the order they began. Empties the list. */
    fun take(): List<Missed> {
        val from = now() - KEEP_MS
        val sums = LinkedHashMap<Pair<String, String>, Int>()
        for (entry in entries) if (entry.at >= from) sums.merge(entry.by to entry.e, entry.n, Int::plus)
        entries.clear()
        return sums.map { (who, n) -> Missed(who.first, who.second, n) }
    }

    companion object {
        const val KEEP_MS = 5 * 60_000L

        /** More than this many in a pocket are not kept: the oldest go. */
        const val MAX_ENTRIES = 200
    }
}
