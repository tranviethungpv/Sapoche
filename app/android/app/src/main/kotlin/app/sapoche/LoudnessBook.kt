package app.sapoche

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

/**
 * How loud songs are against YouTube's reference level, as their streams say (see [app.sapoche.core.Loudness]). What a
 * stream says is kept in the library as well, so that a song kept on the phone is evened out without a network too.
 * [heard] is called from the thread that loads the song.
 */
class LoudnessBook(private val library: LibraryStore, private val scope: CoroutineScope) {
    private val known = ConcurrentHashMap<String, Double>()

    /** Told when a song's loudness became known or changed; may be called from any thread. */
    @Volatile
    var onHeard: (String) -> Unit = {}

    fun heard(videoId: String, db: Double) {
        // A song is opened once for every piece of it that is read: only news is told and written
        if (known.put(videoId, db) == db) return
        onHeard(videoId)
        scope.launch { runCatching { library.setLoudness(videoId, db) } }
    }

    /** What this run knows of [videoId]. */
    fun of(videoId: String): Double? = known[videoId]

    /** What the library kept of [videoId] from an earlier run; also remembered for [of]. */
    suspend fun stored(videoId: String): Double? =
        library.loudness(videoId)?.also { known.putIfAbsent(videoId, it) }
}
