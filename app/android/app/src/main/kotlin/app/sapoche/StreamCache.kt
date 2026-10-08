package app.sapoche

import app.sapoche.core.AudioPicker
import app.sapoche.core.AudioQuality
import app.sapoche.core.AudioSource
import app.sapoche.core.Probe
import app.sapoche.core.StreamResolver
import app.sapoche.core.VideoPicker
import app.sapoche.core.VideoSource
import app.sapoche.sync.LoadFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.schabi.newpipe.extractor.exceptions.ContentNotAvailableException
import org.schabi.newpipe.extractor.exceptions.ContentNotSupportedException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap

/**
 * Resolves video ids to playable stream URLs, validates them, and caches them.
 *
 * Some URLs handed out by YouTube are silently broken: the first bytes download but
 * the middle of the file returns 403. Each fresh URL is therefore probed and re-resolved
 * a few times before we give it to the player.
 *
 * All methods block; they are meant to run on the player's loader thread. A resolve itself runs apart from the thread
 * that asked for it and is shared by everyone who wants the same video, so a load the player gives up on (another song
 * was tapped) does not throw away a resolve that the next load of that song can use.
 */
class StreamCache(
    private val resolver: StreamResolver,
    private val probe: Probe,
) {
    private data class Entry(
        val best: AudioSource,
        val audio: List<AudioSource>,
        val videos: List<VideoSource>,
        val resolvedAtMs: Long,
    ) {
        val url get() = best.url
    }

    /** An audio stream to read a song from: its address, which stream it is, and whether the pinned one was followed. */
    data class AudioPick(val url: String, val itag: Int, val honoursPin: Boolean)
    private data class VideoEntry(val url: String, val resolvedAtMs: Long)

    private val entries = ConcurrentHashMap<String, Entry>()
    private val videoEntries = ConcurrentHashMap<String, VideoEntry>()
    private val locks = ConcurrentHashMap<String, Any>()
    private val resolving = ConcurrentHashMap<String, Deferred<Entry>>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Returns a validated stream URL for [videoId], resolving if needed. */
    fun get(videoId: String): String = getAudio(videoId, null).url

    /**
     * Returns a validated audio stream for [videoId], resolving if needed. With [pinnedItag] (the stream the bytes
     * kept on disk belong to) that stream is used as long as the video offers it and it works; see [AudioPicker].
     * Without one, [quality] decides which stream.
     */
    fun getAudio(videoId: String, pinnedItag: Int?, quality: AudioQuality = AudioQuality.MAX): AudioPick {
        val entry = entry(videoId)
        val pick = AudioPicker.pick(entry.audio, pinnedItag, quality) ?: throw IOException("$videoId has no audio stream")
        // The best stream was probed when it was resolved; another one has not been looked at yet
        if (pick.source.itag == entry.best.itag) return AudioPick(pick.source.url, pick.source.itag, pick.honoursPin)
        val probed = runBlocking { probe.check(pick.source) }
        EventLog.d("resolve", "$videoId pinned itag=${pick.source.itag} probe=${probed.headStatus}/${probed.midStatus}/${probed.tailStatus}")
        return if (probed.ok) {
            AudioPick(pick.source.url, pick.source.itag, pick.honoursPin)
        } else {
            AudioPick(entry.best.url, entry.best.itag, false)
        }
    }

    /**
     * Returns a validated URL of the picture-only stream for [videoId], the tallest one within
     * [maxHeight] (see [VideoPicker]). It comes from the same resolve as the audio URL.
     */
    fun getVideo(videoId: String, maxHeight: Int): String {
        val key = "$videoId@$maxHeight"
        videoEntries[key]?.takeIf { System.currentTimeMillis() - it.resolvedAtMs < MAX_AGE_MS }?.let { return it.url }
        synchronized(locks.getOrPut(videoId) { Any() }) {
            videoEntries[key]?.takeIf { System.currentTimeMillis() - it.resolvedAtMs < MAX_AGE_MS }?.let { return it.url }
            var lastProblem = "unknown"
            for (attempt in 1..MAX_ATTEMPTS) {
                val entry = entry(videoId)
                val pick = VideoPicker.pick(entry.videos, maxHeight)
                    ?: throw IOException("$videoId has no video stream")
                val probed = runBlocking { probe.check(pick.url, pick.contentLength) }
                EventLog.d(
                    "resolve",
                    "$videoId video attempt=$attempt itag=${pick.itag} ${pick.height}p ${pick.format} ${pick.codec} " +
                        "${pick.bitrateKbps}kbps probe=${probed.headStatus}/${probed.midStatus}/${probed.tailStatus} " +
                        if (probed.ok) "OK" else "POISONED",
                )
                if (probed.ok) {
                    videoEntries[key] = VideoEntry(pick.url, System.currentTimeMillis())
                    return pick.url
                }
                lastProblem = "probe ${probed.headStatus}/${probed.midStatus}/${probed.tailStatus}"
                entries.remove(videoId) // the next round resolves again
            }
            throw IOException("Could not get a working video stream for $videoId after $MAX_ATTEMPTS attempts ($lastProblem)")
        }
    }

    /** Drops the cached URLs so the next [get] resolves again. */
    fun invalidate(videoId: String) {
        entries.remove(videoId)
        videoEntries.keys.removeIf { it.startsWith("$videoId@") }
    }

    /**
     * The kept streams of [videoId], or those of a resolve: the one already running for it if there is one (preload,
     * or a load the player gave up on), else a new one. Waiting stops when the player cancels the load, the resolve
     * carries on.
     */
    private fun entry(videoId: String): Entry {
        entries[videoId]?.takeIf { isFresh(it) }?.let { return it }
        val shared = resolving.computeIfAbsent(videoId) { id ->
            // Started only once it is in the map, so that finishing at once cannot leave it there
            scope.async(start = CoroutineStart.LAZY) { resolveValidated(id) }
                .also { resolve -> resolve.invokeOnCompletion { resolving.remove(id, resolve) } }
        }
        shared.start()
        return try {
            runBlocking { shared.await() }
        } catch (e: InterruptedException) {
            throw InterruptedIOException("Waiting for $videoId was cancelled")
        } catch (e: CancellationException) {
            throw InterruptedIOException("Waiting for $videoId was cancelled")
        }
    }

    private suspend fun resolveValidated(videoId: String): Entry {
        var lastProblem = "unknown"
        var lastError: Exception? = null
        for (attempt in 1..MAX_ATTEMPTS) {
            try {
                val resolved = resolver.resolve(videoId)
                val probed = probe.check(resolved.best)
                EventLog.d(
                    "resolve",
                    "$videoId attempt=$attempt resolve=${resolved.resolveMs}ms itag=${resolved.best.itag} " +
                        "${resolved.best.codec} ${resolved.best.bitrateKbps}kbps " +
                        "probe=${probed.headStatus}/${probed.midStatus}/${probed.tailStatus} " +
                        "firstByte=${probed.firstByteMs}ms ${if (probed.ok) "OK" else "POISONED"}",
                )
                if (probed.ok) {
                    return Entry(resolved.best, resolved.all, resolved.videos, System.currentTimeMillis())
                        .also { entries[videoId] = it }
                }
                lastProblem = "probe ${probed.headStatus}/${probed.midStatus}/${probed.tailStatus}"
                lastError = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                lastProblem = "${e.javaClass.simpleName}: ${e.message?.lineSequence()?.firstOrNull()}"
                lastError = e
                EventLog.d("resolve", "$videoId attempt=$attempt failed: $lastProblem")
                // Removed, private, blocked in this country, age restricted, live: no try will play it
                if (e is ContentNotAvailableException || e is ContentNotSupportedException) {
                    throw LoadFailure(LoadFailure.Reason.UNPLAYABLE, "$videoId cannot be played ($lastProblem)", e)
                }
                // Without a network every try fails at once: a network that is only changing gets a moment
                if (isOffline(e) && attempt < MAX_ATTEMPTS) delay(OFFLINE_RETRY_MS)
            }
        }
        if (isOffline(lastError)) throw LoadFailure(LoadFailure.Reason.OFFLINE, "No network to get $videoId ($lastProblem)", lastError)
        throw ResolveFailed("Could not get a working stream for $videoId after $MAX_ATTEMPTS attempts ($lastProblem)")
    }

    /** The tries to get a working stream were all used up; the player does not try again by itself, see [PatientLoadErrorPolicy]. */
    class ResolveFailed(message: String) : IOException(message)

    /** YouTube could not even be reached: no network, or none that goes anywhere. */
    private fun isOffline(error: Throwable?) = generateSequence(error) { it.cause }.take(8)
        .any { it is UnknownHostException || it is ConnectException || it is NoRouteToHostException }

    // Stream URLs expire after about 6 hours; stay well inside that
    private fun isFresh(entry: Entry) = System.currentTimeMillis() - entry.resolvedAtMs < MAX_AGE_MS

    private companion object {
        const val MAX_ATTEMPTS = 3
        const val MAX_AGE_MS = 4 * 60 * 60 * 1000L
        const val OFFLINE_RETRY_MS = 500L
    }
}
