package app.sapoche.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

/**
 * How this device introduces itself to YouTube. The visionOS app of YouTube is what gives audio streams that need no
 * sign-in and no proof-of-origin token (the iPhone does the same, see `InnertubeClient` in `YouTube.swift`). If YouTube
 * retires it, this is the one place to change.
 */
data class InnertubeClient(
    val name: String,
    val id: Int,
    val version: String,
    val model: String,
    val osName: String,
    val osVersion: String,
    val userAgent: String,
) {
    fun context(region: String, visitorData: String?) = buildJsonObject {
        put(
            "client",
            buildJsonObject {
                put("clientName", name)
                put("clientVersion", version)
                put("deviceMake", "Apple")
                put("deviceModel", model)
                put("osName", osName)
                put("osVersion", osVersion)
                put("hl", "en")
                put("gl", region)
                if (visitorData != null) put("visitorData", visitorData)
            },
        )
    }

    fun headers(visitorData: String?): Map<String, String> = buildMap {
        put("User-Agent", userAgent)
        put("X-YouTube-Client-Name", id.toString())
        put("X-YouTube-Client-Version", version)
        if (visitorData != null) put("X-Goog-Visitor-Id", visitorData)
    }

    companion object {
        val VISIONOS = InnertubeClient(
            name = "VISIONOS", id = 101, version = "1.02", model = "RealityDevice14,1", osName = "visionOS", osVersion = "25.6.0",
            userAgent = "com.google.visionos.youtube/1.02(RealityDevice14,1; U; CPU visionOS 25_6_0 like Mac OS X;)",
        )
    }
}

/** Sends a request to YouTube's app API and gives back the answer text. */
fun interface InnertubeTransport {
    suspend fun post(endpoint: String, headers: Map<String, String>, body: String): String
}

class OkHttpInnertube(private val client: OkHttpClient = OkHttpDownloader.defaultClient()) : InnertubeTransport {
    override suspend fun post(endpoint: String, headers: Map<String, String>, body: String): String = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url("https://youtubei.googleapis.com/youtubei/v1/$endpoint?prettyPrint=false")
            .apply { headers.forEach { (name, value) -> header(name, value) } }
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("YouTube answered ${response.code} to $endpoint")
            response.body.string()
        }
    }
}

/** YouTube answered, but not with streams to play. Which video it is about is not decided here: see [InnertubePlayer]. */
class InnertubeRefused(message: String, val status: String? = null) : IOException(message)

/**
 * Gets the streams of a video from the app API of YouTube in two small requests (an identity, then `player`), where
 * NewPipeExtractor reads the page, the related list and several clients and solves signatures. Any failure here is
 * only a reason to ask NewPipeExtractor instead: it alone says that a video cannot be played, so that one refusal of
 * this client does not mark a good video as broken.
 */
class InnertubePlayer(
    private val region: () -> String = { "US" },
    private val transport: InnertubeTransport = OkHttpInnertube(),
    private val client: InnertubeClient = InnertubeClient.VISIONOS,
    private val visitors: VisitorSource = FreshVisitors(client, region, transport),
) {
    suspend fun resolve(videoId: String): Resolved {
        val t0 = System.nanoTime()
        val visitorData = visitors.take()
        val t1 = System.nanoTime()
        val resolved = try {
            parse(ask(visitorData, videoId), videoId)
        } catch (e: InnertubeRefused) {
            // An identity asked for in advance can have gone stale: the bot check then says so, and a new one gets through
            if (e.status != "LOGIN_REQUIRED" || !visitors.keeps) throw e
            parse(ask(visitors.fresh(), videoId), videoId)
        }
        val steps = "visitor=${(t1 - t0) / 1_000_000}ms player=${(System.nanoTime() - t1) / 1_000_000}ms"
        return resolved.copy(resolveMs = (System.nanoTime() - t0) / 1_000_000, steps = steps)
    }

    private suspend fun ask(visitorData: String?, videoId: String): JsonElement {
        val body = buildJsonObject {
            put("context", client.context(region().ifBlank { "US" }, visitorData))
            put("videoId", videoId)
            put("contentCheckOk", true)
            put("racyCheckOk", true)
        }
        return Json.parseToJsonElement(transport.post("player", client.headers(visitorData), body.toString()))
    }

    companion object {
        const val VIA = "visionos"

        /** The song and its streams from a `player` answer. */
        fun parse(root: JsonElement, videoId: String): Resolved {
            val status = root.at("playabilityStatus", "status").string()
            if (status != "OK") {
                throw InnertubeRefused(root.at("playabilityStatus", "reason").string() ?: "The video is not available ($status)", status)
            }
            val details = root.at("videoDetails")
            val length = details.at("lengthSeconds").string()?.toLongOrNull() ?: 0
            if (details.at("isLive").bool() == true || length <= 0) throw InnertubeRefused("Live streams cannot be played")

            val formats = root.at("streamingData", "adaptiveFormats").elements()
            val trackLoudness = trackLoudness(root)
            val audio = formats.mapNotNull { audioSource(it, trackLoudness) }.sortedByDescending { it.bitrateKbps }
            if (audio.isEmpty()) throw InnertubeRefused("No audio stream available for $videoId")
            val videos = formats.mapNotNull(::videoSource).sortedByDescending { it.height }

            val thumb = details.at("thumbnail", "thumbnails").elements()
                .maxByOrNull { it.at("width").string()?.toIntOrNull() ?: 0 }.at("url").string()
            return Resolved(
                track = TrackInfo(
                    videoId = videoId,
                    title = details.at("title").string() ?: "",
                    artist = details.at("author").string() ?: "",
                    thumbUrl = thumb,
                    durationSec = length,
                ),
                best = audio.first(),
                all = audio,
                resolveMs = 0,
                videos = videos,
                via = VIA,
            )
        }

        private fun audioSource(format: JsonElement, trackLoudness: Double?): AudioSource? {
            val mime = format.at("mimeType").string() ?: return null
            val url = format.at("url").string() ?: return null
            if (!mime.startsWith("audio/")) return null
            // A video with dubbed sound lists one stream per language: the song is the original one
            if (format.at("audioTrack", "audioIsDefault").bool() == false) return null
            val bitrate = format.at("averageBitrate").string()?.toDoubleOrNull() ?: format.at("bitrate").string()?.toDoubleOrNull() ?: 0.0
            return AudioSource(
                url = url,
                codec = if (mime.startsWith("audio/webm")) "WEBMA_OPUS" else "M4A",
                bitrateKbps = (bitrate / 1000).toInt(),
                contentLength = format.at("contentLength").string()?.toLongOrNull() ?: -1,
                itag = format.at("itag").string()?.toIntOrNull() ?: -1,
                loudnessDb = format.at("loudnessDb").string()?.toDoubleOrNull() ?: trackLoudness,
            )
        }

        private fun videoSource(format: JsonElement): VideoSource? {
            val mime = format.at("mimeType").string() ?: return null
            val url = format.at("url").string() ?: return null
            val height = format.at("height").string()?.toIntOrNull() ?: return null
            if (!mime.startsWith("video/") || height <= 0) return null
            return VideoSource(
                url = url,
                height = height,
                format = if (mime.startsWith("video/webm")) "WEBM" else "MPEG_4",
                codec = CODECS.find(mime)?.groupValues?.get(1) ?: "",
                bitrateKbps = (format.at("bitrate").string()?.toIntOrNull() ?: 0) / 1000,
                contentLength = format.at("contentLength").string()?.toLongOrNull() ?: -1,
                itag = format.at("itag").string()?.toIntOrNull() ?: -1,
            )
        }

        /**
         * How far above YouTube's reference level (the `loudnessTargetLkfs` of the answer, -14) the song is, for a stream
         * that does not say so itself: the answer gives the loudness of the whole song as an absolute number of LKFS.
         */
        private fun trackLoudness(root: JsonElement): Double? {
            val config = root.at("playerConfig", "audioConfig")
            val absolute = config.at("perceptualLoudnessDb").string()?.toDoubleOrNull() ?: return null
            return absolute - (config.at("loudnessTargetLkfs").string()?.toDoubleOrNull() ?: DEFAULT_TARGET_LKFS)
        }

        private const val DEFAULT_TARGET_LKFS = -14.0
        private val CODECS = Regex("codecs=\"([^\"]*)\"")
    }
}

/** Where the identity for a `player` request comes from; see [InnertubePlayer]. */
interface VisitorSource {
    /** An identity to ask with, maybe one asked for in advance. */
    suspend fun take(): String?

    /** An identity asked for just now. */
    suspend fun fresh(): String?

    /** Whether [take] can give something other than what [fresh] does, so that asking again with [fresh] can help. */
    val keeps: Boolean get() = false
}

/**
 * An identity YouTube gives to a visitor; asking for streams with one is what keeps it from calling us a robot. A new
 * one is asked for every time, as NewPipeExtractor does: one kept across many songs was seen to get only streams that
 * broke with 403 after their first moments (see `docs/systems/ios.md`).
 */
class FreshVisitors(
    private val client: InnertubeClient = InnertubeClient.VISIONOS,
    private val region: () -> String = { "US" },
    private val transport: InnertubeTransport = OkHttpInnertube(),
) : VisitorSource {
    override suspend fun take() = fresh()

    override suspend fun fresh(): String? {
        val body = buildJsonObject { put("context", client.context(region().ifBlank { "US" }, null)) }
        val answer = Json.parseToJsonElement(transport.post("visitor_id", client.headers(null), body.toString()))
        return answer.at("responseContext", "visitorData").string()
    }
}

/**
 * Keeps one identity asked for in the background and gives it out once, so that a song costs only its `player` request;
 * a new one is asked for as soon as it is taken. One that has waited longer than [maxAgeMs] is not used. Unlike the
 * identity kept for an hour that broke every stream, none is used for two songs.
 */
class PrefetchedVisitors(
    private val source: VisitorSource,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
    private val maxAgeMs: Long = 10 * 60 * 1000L,
) : VisitorSource {
    private class Spare(val id: String, val askedAtMs: Long)

    private val lock = Any()
    private var spare: Spare? = null
    private var asking = false

    init {
        refill()
    }

    override val keeps get() = true

    override suspend fun take(): String? {
        val kept = synchronized(lock) { spare.also { spare = null } }
        refill()
        return kept?.takeIf { now() - it.askedAtMs < maxAgeMs }?.id ?: source.fresh()
    }

    override suspend fun fresh(): String? = source.fresh()

    private fun refill() {
        synchronized(lock) {
            if (spare != null || asking) return
            asking = true
        }
        scope.launch {
            val asked = try {
                source.fresh()?.let { Spare(it, now()) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null // the next song asks for its own
            }
            synchronized(lock) {
                spare = asked
                asking = false
            }
        }
    }
}

private fun JsonElement?.at(vararg path: String): JsonElement? {
    var node = this
    for (step in path) {
        node = when (node) {
            is JsonObject -> node[step]
            is JsonArray -> step.toIntOrNull()?.let { node.getOrNull(it) }
            else -> null
        } ?: return null
    }
    return node
}

private fun JsonElement?.string(): String? = (this as? JsonPrimitive)?.contentOrNull
private fun JsonElement?.bool(): Boolean? = (this as? JsonPrimitive)?.booleanOrNull
private fun JsonElement?.elements(): List<JsonElement> = (this as? JsonArray)?.toList() ?: emptyList()
