package app.unison

import app.unison.core.AudioPicker
import app.unison.core.AudioSource
import app.unison.core.Probe
import app.unison.core.StreamResolver
import app.unison.core.VideoPicker
import app.unison.core.VideoSource
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/**
 * Resolves video ids to playable stream URLs, validates them, and caches them.
 *
 * Some URLs handed out by YouTube are silently broken: the first bytes download but
 * the middle of the file returns 403. Each fresh URL is therefore probed and re-resolved
 * a few times before we give it to the player.
 *
 * All methods block; they are meant to run on the player's loader thread.
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

    /** Returns a validated stream URL for [videoId], resolving if needed. */
    fun get(videoId: String): String = getAudio(videoId, null).url

    /**
     * Returns a validated audio stream for [videoId], resolving if needed. With [pinnedItag] (the stream the bytes
     * kept on disk belong to) that stream is used as long as the video offers it and it works; see [AudioPicker].
     */
    fun getAudio(videoId: String, pinnedItag: Int?): AudioPick {
        val entry = entries[videoId]?.takeIf { isFresh(it) } ?: run {
            // One resolve per video at a time, so preload and playback do not race
            synchronized(locks.getOrPut(videoId) { Any() }) {
                entries[videoId]?.takeIf { isFresh(it) } ?: run {
                    resolveValidated(videoId)
                    entries.getValue(videoId)
                }
            }
        }
        val pick = AudioPicker.pick(entry.audio, pinnedItag) ?: throw IOException("$videoId has no audio stream")
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
                val entry = entries[videoId]?.takeIf { isFresh(it) } ?: run {
                    resolveValidated(videoId)
                    entries.getValue(videoId)
                }
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

    private fun resolveValidated(videoId: String): String = runBlocking {
        var lastProblem = "unknown"
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
                    entries[videoId] = Entry(resolved.best, resolved.all, resolved.videos, System.currentTimeMillis())
                    return@runBlocking resolved.best.url
                }
                lastProblem = "probe ${probed.headStatus}/${probed.midStatus}/${probed.tailStatus}"
            } catch (e: Exception) {
                lastProblem = "${e.javaClass.simpleName}: ${e.message?.lineSequence()?.firstOrNull()}"
                EventLog.d("resolve", "$videoId attempt=$attempt failed: $lastProblem")
            }
        }
        throw IOException("Could not get a working stream for $videoId after $MAX_ATTEMPTS attempts ($lastProblem)")
    }

    // Stream URLs expire after about 6 hours; stay well inside that
    private fun isFresh(entry: Entry) = System.currentTimeMillis() - entry.resolvedAtMs < MAX_AGE_MS

    private companion object {
        const val MAX_ATTEMPTS = 3
        const val MAX_AGE_MS = 4 * 60 * 60 * 1000L
    }
}
