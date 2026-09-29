package app.unison.sync

import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

// Wire protocol with the room server. Mirrors server/src/protocol.ts and docs/PROTOCOL.md.

@Serializable
data class QueueItem(
    val id: String,
    val videoId: String,
    val title: String,
    val artist: String,
    val thumb: String? = null,
    val durMs: Long,
    val addedBy: String,
)

/** A song to put on the queue; the server adds the item id and who added it. */
data class TrackRef(val videoId: String, val title: String, val artist: String, val thumb: String?, val durMs: Long)

/** Room state as broadcast by the server. [phase] is one of idle, preparing, playing, paused. */
@Serializable
data class RoomState(
    val queue: List<QueueItem>,
    val index: Int,
    val phase: String,
    /** Server time at which position 0 of the current item is played. Valid while playing. */
    val startedAt: Long,
    /** Position in the current item; authoritative while paused or preparing. */
    val positionMs: Long,
    val epoch: Long,
    /** What happens when an item ends: off (stop after the queue), all (start over) or one (same item). */
    val repeat: String = "off",
) {
    val current: QueueItem? get() = queue.getOrNull(index)
}

@Serializable
data class Member(val id: String, val name: String, val ready: Boolean)

sealed interface ServerMessage {
    @Serializable
    data class State(
        val serverNow: Long,
        val you: String,
        val state: RoomState,
        val members: List<Member>,
        /** Protocol version of the server; 0 when an older server does not say. */
        val protocol: Int = 0,
    ) : ServerMessage

    @Serializable
    data class Members(val members: List<Member>) : ServerMessage

    @Serializable
    data class Prepare(val epoch: Long, val index: Int, val item: QueueItem, val seekToMs: Long) : ServerMessage

    /** Play so that position [positionMs] is heard at server time [startAt]. */
    @Serializable
    data class Start(val epoch: Long, val startAt: Long, val positionMs: Long) : ServerMessage

    @Serializable
    data class Pause(val epoch: Long, val positionMs: Long) : ServerMessage

    /** The room moved on to the item at [index]; position 0 of it was heard at server time [startedAt]. */
    @Serializable
    data class Advance(val epoch: Long, val index: Int, val startedAt: Long) : ServerMessage

    @Serializable
    data class Pong(val c0: Long, val s1: Long) : ServerMessage

    @Serializable
    data class Error(val code: String, val message: String) : ServerMessage
}

object Protocol {
    val json = Json { ignoreUnknownKeys = true }

    /** Returns null for anything that is not a well-formed message we understand. */
    fun parse(text: String): ServerMessage? {
        return try {
            val obj = json.parseToJsonElement(text).jsonObject
            when (obj["t"]?.jsonPrimitive?.content) {
                "state" -> json.decodeFromJsonElement<ServerMessage.State>(obj)
                "members" -> json.decodeFromJsonElement<ServerMessage.Members>(obj)
                "prepare" -> json.decodeFromJsonElement<ServerMessage.Prepare>(obj)
                "start" -> json.decodeFromJsonElement<ServerMessage.Start>(obj)
                "pause" -> json.decodeFromJsonElement<ServerMessage.Pause>(obj)
                "advance" -> json.decodeFromJsonElement<ServerMessage.Advance>(obj)
                "pong" -> json.decodeFromJsonElement<ServerMessage.Pong>(obj)
                "error" -> json.decodeFromJsonElement<ServerMessage.Error>(obj)
                else -> null
            }
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    // ---- client -> server ----

    fun join(clientId: String, name: String) = msg("join") { put("clientId", clientId); put("name", name) }

    fun ping(c0: Long) = msg("ping") { put("c0", c0) }

    /** With [playNext] the track goes right after the current one instead of at the end. */
    fun queueAdd(videoId: String, title: String, artist: String, thumb: String?, durMs: Long, playNext: Boolean = false) =
        msg("queue.add") {
            put("videoId", videoId)
            put("title", title)
            put("artist", artist)
            if (thumb != null) put("thumb", thumb)
            put("durMs", durMs)
            if (playNext) put("next", true)
        }

    /** A playlist in one message. With [playNext] the songs go right after the current one. */
    fun queueAddMany(tracks: List<TrackRef>, playNext: Boolean = false) = msg("queue.addMany") {
        put("tracks", buildJsonArray {
            tracks.forEach { track ->
                add(buildJsonObject {
                    put("videoId", track.videoId)
                    put("title", track.title)
                    put("artist", track.artist)
                    if (track.thumb != null) put("thumb", track.thumb)
                    put("durMs", track.durMs)
                })
            }
        })
        if (playNext) put("next", true)
    }

    fun repeat(mode: String) = msg("repeat") { put("mode", mode) }

    fun queueRemove(id: String) = msg("queue.remove") { put("id", id) }

    fun queueClear() = msg("queue.clear")

    /** Move queue item [id] so that it ends up at [toIndex]. */
    fun queueMove(id: String, toIndex: Int) = msg("queue.move") { put("id", id); put("toIndex", toIndex) }

    /** Start playing the queue item [id] from the beginning. */
    fun jump(id: String) = msg("jump") { put("id", id) }

    fun play() = msg("play")

    fun pause() = msg("pause")

    fun seek(positionMs: Long) = msg("seek") { put("positionMs", positionMs) }

    fun next() = msg("next")

    fun prev() = msg("prev")

    fun ready(epoch: Long) = msg("ready") { put("epoch", epoch) }

    fun resolveFailed(epoch: Long, reason: String?) = msg("resolveFailed") {
        put("epoch", epoch)
        if (reason != null) put("reason", reason.take(200))
    }

    fun ended(epoch: Long) = msg("ended") { put("epoch", epoch) }

    /** This device moved on to queue item [itemId] by itself; position 0 was heard at [startedAt] (server time). */
    fun advanced(epoch: Long, itemId: String, startedAt: Long) = msg("advanced") {
        put("epoch", epoch)
        put("itemId", itemId)
        put("startedAt", startedAt)
    }

    private fun msg(t: String, block: JsonObjectBuilder.() -> Unit = {}): String =
        buildJsonObject {
            put("t", t)
            block()
        }.toString()
}
