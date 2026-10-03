package app.sapoche.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File

/** What was kept for a song: its lyrics, or the knowledge that there are none. */
sealed interface KeptLyrics {
    data class Found(val lyrics: Lyrics) : KeptLyrics

    /** Looked for [checkedAt] and not found; asking again is worth it after a while. */
    data class Missing(val checkedAt: Long) : KeptLyrics
}

/**
 * Lyrics kept in files, one per song, so that a song played again has its words at once and offline. Only the
 * newest [maxEntries] files stay.
 */
class LyricsStore(private val dir: File, private val maxEntries: Int = 400) {

    fun get(videoId: String): KeptLyrics? {
        val file = file(videoId)
        if (!file.isFile) return null
        return try {
            val json = Json.parseToJsonElement(file.readText()) as JsonObject
            val missing = json["missing"]?.jsonPrimitive?.longOrNull
            if (missing != null) return KeptLyrics.Missing(missing)
            val lines = (json["lines"] as? JsonArray).orEmpty().map {
                val pair = it as JsonArray
                LyricLine(pair[0].jsonPrimitive.long(), pair[1].jsonPrimitive.contentOrNull.orEmpty())
            }
            KeptLyrics.Found(Lyrics(lines, json["plain"]?.jsonPrimitive?.contentOrNull))
        } catch (e: Exception) {
            // A file cut short by a crash is as good as none
            file.delete()
            null
        }
    }

    fun putFound(videoId: String, lyrics: Lyrics) = write(
        videoId,
        buildJsonObject {
            put("lines", buildJsonArray { lyrics.lines.forEach { add(buildJsonArray { add(JsonPrimitive(it.ms)); add(JsonPrimitive(it.text)) }) } })
            lyrics.plain?.let { put("plain", it) }
        },
    )

    fun putMissing(videoId: String, checkedAt: Long) = write(videoId, buildJsonObject { put("missing", checkedAt) })

    private fun write(videoId: String, json: JsonObject) {
        dir.mkdirs()
        val file = file(videoId)
        val part = File(dir, "${file.name}.part")
        part.writeText(json.toString())
        part.renameTo(file)
        trim()
    }

    private fun trim() {
        val files = dir.listFiles { f -> f.name.endsWith(".json") } ?: return
        files.sortedByDescending { it.lastModified() }.drop(maxEntries).forEach { it.delete() }
    }

    // A video id has only letters, digits, - and _, but nothing is written with a name that came from outside unchecked
    private fun file(videoId: String) = File(dir, videoId.filter { it.isLetterOrDigit() || it == '-' || it == '_' } + ".json")

    private fun JsonPrimitive.long() = longOrNull ?: 0L
}
