package app.sapoche.core

import kotlinx.coroutines.CancellationException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException

/**
 * Gets the streams of a song the quick way ([InnertubePlayer]) and, when that fails for any reason, the slow way
 * ([full], NewPipeExtractor). Only [full] says that a song cannot be played (it throws the exceptions that say so), so a
 * single refusal of the quick way never marks a good song as broken; everything else it does is [full]'s.
 */
class QuickFirstResolver(
    private val quick: suspend (String) -> Resolved,
    private val full: StreamResolver,
    private val log: (String) -> Unit = {},
) : StreamResolver by full {

    override suspend fun resolve(videoId: String): Resolved = try {
        quick(videoId)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        // Without a network the other way fails just as surely, and after as long a wait
        if (isOffline(e)) throw e
        log("$videoId quick way failed (${e.javaClass.simpleName}: ${e.message?.lineSequence()?.firstOrNull()}), asking NewPipeExtractor")
        full.resolve(videoId)
    }

    private fun isOffline(error: Throwable) = generateSequence(error) { it.cause }.take(8)
        .any { it is UnknownHostException || it is ConnectException || it is NoRouteToHostException }
}
