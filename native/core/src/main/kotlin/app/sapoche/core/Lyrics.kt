package app.sapoche.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import kotlin.math.abs

/** One line of a song, sung from [ms] on. */
data class LyricLine(val ms: Long, val text: String)

/** The words of a song. [lines] carry times when the lyrics run along with the music; otherwise only [plain] is known. */
data class Lyrics(val lines: List<LyricLine>, val plain: String?) {
    val synced get() = lines.isNotEmpty()
}

/** Reads the `[mm:ss.xx] words` format that lyrics with times come in. */
object Lrc {
    private val TAG = Regex("""\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?]""")

    /** Lines in time order. A line with several times gives one line for each; tags like `[ar:Name]` are skipped. */
    fun parse(text: String): List<LyricLine> = text.lineSequence().flatMap { line ->
        val tags = TAG.findAll(line).toList()
        val words = TAG.replace(line, "").trim()
        tags.map { tag ->
            val (minutes, seconds, fraction) = tag.destructured
            // ".5" is half a second and ".500" too
            val ms = (minutes.toLong() * 60 + seconds.toLong()) * 1000 + (fraction.padEnd(3, '0').take(3).toLongOrNull() ?: 0)
            LyricLine(ms, words)
        }
    }.sortedBy { it.ms }.toList()
}

/** Gets one address and gives its text, or null when there is nothing there (404). */
fun interface LyricsFetch {
    suspend fun get(url: String): String?
}

/**
 * Lyrics that run along with the music, from [LRCLIB](https://lrclib.net): a free service kept by volunteers that
 * needs no key. It is told the title, artist and length of the song, nothing else.
 */
class LyricsClient(private val fetch: LyricsFetch = OkHttpFetch()) {

    /** The lyrics of the song, or null when LRCLIB has none. The exact name is tried first, then the name without tags. */
    suspend fun find(title: String, artist: String, durationSec: Long): Lyrics? {
        val names = listOf(title to artist, SongNames.title(title, artist) to SongNames.artist(artist)).distinct()
        for ((t, a) in names) {
            exact(t, a, durationSec)?.let { return it }
        }
        val (t, a) = names.last()
        return closest(t, a, durationSec)
    }

    private suspend fun exact(title: String, artist: String, durationSec: Long): Lyrics? {
        val body = fetch.get(url("get", "track_name" to title, "artist_name" to artist, "duration" to durationSec.takeIf { it > 0 }?.toString())) ?: return null
        return (Json.parseToJsonElement(body) as? JsonObject)?.let(::lyricsOf)
    }

    /** With no exact match, the song of about the same length that has the most to show. */
    private suspend fun closest(title: String, artist: String, durationSec: Long): Lyrics? {
        val body = fetch.get(url("search", "track_name" to title, "artist_name" to artist)) ?: return null
        val candidates = (Json.parseToJsonElement(body) as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
        val near = candidates.filter { durationSec <= 0 || abs((it["duration"]?.jsonPrimitive?.doubleOrNull ?: 0.0) - durationSec) <= MAX_LENGTH_GAP_SEC }
        return near.mapNotNull(::lyricsOf).let { found -> found.firstOrNull { it.synced } ?: found.firstOrNull() }
    }

    private fun lyricsOf(item: JsonObject): Lyrics? {
        if (item["instrumental"]?.jsonPrimitive?.booleanOrNull == true) return null
        val lines = item["syncedLyrics"]?.jsonPrimitive?.contentOrNull?.let(Lrc::parse).orEmpty()
        val plain = item["plainLyrics"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }
        return if (lines.isEmpty() && plain == null) null else Lyrics(lines, plain)
    }

    private fun url(path: String, vararg query: Pair<String, String?>) =
        "https://lrclib.net/api/$path".toHttpUrl().newBuilder().apply {
            query.forEach { (name, value) -> if (value != null) addQueryParameter(name, value) }
        }.build().toString()

    companion object {
        /** Lyrics of a song this much longer or shorter are probably of another recording. */
        const val MAX_LENGTH_GAP_SEC = 5
    }
}

class OkHttpFetch(private val client: OkHttpClient = OkHttpDownloader.defaultClient()) : LyricsFetch {
    override suspend fun get(url: String): String? = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(url).header("User-Agent", "Sapoche (private group listening app)").build()
        client.newCall(request).execute().use { response ->
            if (response.code == 404) return@use null
            if (!response.isSuccessful) throw IOException("LRCLIB answered ${response.code}")
            response.body.string()
        }
    }
}
