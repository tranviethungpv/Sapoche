package app.sapoche.sync

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.contentOrNull

/** What the person told the taste, kept beside the library as marks of one of these kinds. */
object TasteMarks {
    /** An artist (by [Taste.artistKey]) to be suggested less: not a seed, not known, nothing offered to a room. */
    const val QUIET_ARTIST = "quiet_artist"

    /** A song (by video id) that is not to count: whatever happened to it is left out of the taste. */
    const val QUIET_SONG = "quiet_song"

    /** A song a new person chose an artist by (key: its video id; label: the song as JSON): counts as heard when chosen. */
    const val STARTER = "starter"

    private val json = Json { ignoreUnknownKeys = true }

    /** The song a [STARTER] mark stands for, heard at [at]; null when its [label] is not a song. */
    fun starter(label: String, at: Long): Stamped? =
        try {
            val o = json.parseToJsonElement(label).jsonObject
            val track = TrackRef(
                videoId = o["videoId"]?.jsonPrimitive?.contentOrNull ?: return null,
                title = o["title"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                artist = o["artist"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                thumb = o["thumb"]?.jsonPrimitive?.contentOrNull,
                durMs = o["durMs"]?.jsonPrimitive?.longOrNull ?: 0,
            )
            Stamped(track, at)
        } catch (_: Exception) {
            null
        }
}
