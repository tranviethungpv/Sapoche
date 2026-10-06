package app.sapoche.sync

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
    /** Room name; null when the room has none (or the server is older). */
    val name: String? = null,
    /** Client id of the owner; null while the room has none. */
    val ownerId: String? = null,
    /** While the owner is here: `all` lets every member control the room, `add` lets guests only add songs. */
    val guestControl: String = "all",
    /** Whether the room carries on with songs like the last one when its queue runs out; null when the server is older than protocol 9. */
    val autoplay: Boolean? = null,
) {
    val current: QueueItem? get() = queue.getOrNull(index)
}

@Serializable
data class Member(
    val id: String,
    val name: String,
    val ready: Boolean,
    /** Listening on their own: the room's play, pause and skip do not move this device. */
    val solo: Boolean = false,
    /** Not heard from for a while, probably a dead connection: not counted as listening. */
    val away: Boolean = false,
    /** Can change the room's settings and remove people. */
    val owner: Boolean = false,
    /** Fingerprint of the member's picture; null when they have none. The picture itself comes with [ServerMessage.Avatar]. */
    val av: String? = null,
)

/** A chat message as the room keeps it. [name] is the sender's name when it was sent; [cid] is the id the sending device gave it. */
@Serializable
data class ChatMessage(
    val id: Long,
    val by: String,
    val name: String,
    val text: String,
    /** Server time it was sent at. */
    val at: Long,
    val cid: String? = null,
)

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

    /** [by] is the client id of whoever asked for it; null when the room moved on by itself. */
    @Serializable
    data class Prepare(val epoch: Long, val index: Int, val item: QueueItem, val seekToMs: Long, val by: String? = null) : ServerMessage

    /** Play so that position [positionMs] is heard at server time [startAt]. */
    @Serializable
    data class Start(val epoch: Long, val startAt: Long, val positionMs: Long, val by: String? = null) : ServerMessage

    @Serializable
    data class Pause(val epoch: Long, val positionMs: Long, val by: String? = null) : ServerMessage

    /** The room moved on to the item at [index]; position 0 of it was heard at server time [startedAt]. */
    @Serializable
    data class Advance(val epoch: Long, val index: Int, val startedAt: Long) : ServerMessage

    @Serializable
    data class Pong(val c0: Long, val s1: Long) : ServerMessage

    /** The room's queue ran out and this device is asked to find songs like [videoId] and send them with [Protocol.queueAddMany]. */
    @Serializable
    data class AutoplayFill(val epoch: Long, val videoId: String, val title: String) : ServerMessage

    /** The picture of member [id] as base64, with its fingerprint [av]; both are null when the member has none. */
    @Serializable
    data class Avatar(val id: String, val av: String? = null, val data: String? = null) : ServerMessage

    /** A new chat message, this device's own included. Protocol 10. */
    @Serializable
    data class Chat(val msg: ChatMessage) : ServerMessage

    /** The room's last chat messages, oldest first, sent right after the state on joining. Protocol 10. */
    @Serializable
    data class ChatHistory(val msgs: List<ChatMessage>) : ServerMessage

    /** Member [by] reacted with [e], [n] taps of it. Protocol 10. */
    @Serializable
    data class React(val by: String, val e: String, val n: Int = 1) : ServerMessage

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
                "autoplay.fill" -> json.decodeFromJsonElement<ServerMessage.AutoplayFill>(obj)
                "avatar" -> json.decodeFromJsonElement<ServerMessage.Avatar>(obj)
                "chat" -> json.decodeFromJsonElement<ServerMessage.Chat>(obj)
                "chat.history" -> json.decodeFromJsonElement<ServerMessage.ChatHistory>(obj)
                "react" -> json.decodeFromJsonElement<ServerMessage.React>(obj)
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

    /**
     * [create] says what the device expects: true for a code it just made, false for one it was given, so
     * that a mistyped code is refused instead of opening an empty room. Null leaves it out, as older apps do.
     */
    fun join(clientId: String, name: String, create: Boolean? = null) = msg("join") {
        put("clientId", clientId)
        put("name", name)
        if (create != null) put("create", create)
    }

    /** Leaving on purpose, as opposed to a connection that dropped. */
    fun bye() = msg("bye")

    /** Owner only: disconnect a member. */
    fun kick(id: String) = msg("kick") { put("id", id) }

    fun roomName(name: String) = msg("room.name") { put("name", name) }

    /** Owner only: `all` or `add`. */
    fun roomSettings(guestControl: String) = msg("room.settings") { put("guestControl", guestControl) }

    /**
     * [rttMs] is the best round trip this device has measured; the room uses the slowest of its devices to decide how
     * far ahead to schedule a start. Null leaves it out, as older apps do.
     */
    fun ping(c0: Long, rttMs: Double? = null) = msg("ping") {
        put("c0", c0)
        if (rttMs != null) put("rtt", rttMs.toLong())
    }

    /** The device's own picture as base64 of a small JPEG; null takes it away. Only servers of protocol 8 or newer know it. */
    fun avatarSet(data: String?) = msg("avatar.set") { put("data", data) }

    /** Asks for the picture of the member [id]. */
    fun avatarGet(id: String) = msg("avatar.get") { put("id", id) }

    /** A chat message to the room; [cid] comes back with it, so this device knows it arrived. Protocol 10. */
    fun chat(text: String, cid: String) = msg("chat") {
        put("text", text)
        put("cid", cid)
    }

    /** A reaction ([e] is its name, see `REACTIONS` in server/src/protocol.ts, or the emoji itself) standing for [n] taps. Protocol 10. */
    fun react(e: String, n: Int) = msg("react") {
        put("e", e)
        put("n", n)
    }

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

    /** The room's autoplay, on or off. Only servers of protocol 9 or newer know it. */
    fun autoplay(on: Boolean) = msg("autoplay") { put("on", on) }

    fun queueRemove(id: String) = msg("queue.remove") { put("id", id) }

    /** Put [track], another release of the same song, in place of queue item [id]. */
    fun queueSwap(id: String, track: TrackRef) = msg("queue.swap") {
        put("id", id)
        put("track", buildJsonObject {
            put("videoId", track.videoId)
            put("title", track.title)
            put("artist", track.artist)
            if (track.thumb != null) put("thumb", track.thumb)
            put("durMs", track.durMs)
        })
    }

    fun queueClear() = msg("queue.clear")

    /** Mix up the songs still to come; with nothing playing, mix them all and play from the first. */
    fun queueShuffle() = msg("queue.shuffle")

    /** Move queue item [id] so that it ends up at [toIndex]. */
    fun queueMove(id: String, toIndex: Int) = msg("queue.move") { put("id", id); put("toIndex", toIndex) }

    /** Start playing the queue item [id] from the beginning. */
    fun jump(id: String) = msg("jump") { put("id", id) }

    fun play() = msg("play")

    fun pause() = msg("pause")

    fun seek(positionMs: Long) = msg("seek") { put("positionMs", positionMs) }

    /**
     * [from] is the queue item the button was pressed on; the room ignores the press once it has left that item, so
     * two people skipping at the same moment move it one song, not two. Null leaves it out, as older apps do.
     */
    fun next(from: String? = null) = msg("next") { if (from != null) put("from", from) }

    fun prev(from: String? = null) = msg("prev") { if (from != null) put("from", from) }

    /** Start or stop listening on one's own; a solo device never holds the room back. */
    fun solo(on: Boolean) = msg("solo") { put("on", on) }

    /** Ask for the room's current state again, as when rejoining after listening alone. */
    fun resync() = msg("resync")

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
