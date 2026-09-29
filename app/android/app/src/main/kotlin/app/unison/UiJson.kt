package app.unison

import app.unison.sync.Connection
import app.unison.sync.QueueItem
import org.json.JSONArray
import org.json.JSONObject

/** JSON the Flutter UI receives. The keys are a contract with lib/data/models.dart. */
object UiJson {

    /**
     * Structure of what is playing: the room, or outside one the personal queue in the same shape (no
     * room code, no members). Changes rarely, so the UI only rebuilds when this differs.
     */
    fun state(view: GroupController.View, trimMs: Long, video: Boolean = false, videoHeight: Int = 720): String {
        val snap = view.snapshot
        val state = snap.state
        val local = view.local
        val inRoom = view.roomCode != null
        return JSONObject()
            .put("type", "state")
            .put("room", view.roomCode ?: JSONObject.NULL)
            .put("connection", connectionName(view))
            .put("you", snap.you ?: JSONObject.NULL)
            // Outside a room whether it plays is the player's business; this only says whether there is something to play
            .put("phase", if (inRoom) state?.phase ?: "idle" else if (local.queue.isEmpty() || local.finished) "idle" else "paused")
            .put("repeat", if (inRoom) state?.repeat ?: "off" else local.repeat)
            .put("index", if (inRoom) state?.index ?: 0 else local.index)
            .put("name", state?.name.takeIf { inRoom } ?: JSONObject.NULL)
            .put("ownerId", state?.ownerId.takeIf { inRoom } ?: JSONObject.NULL)
            .put("guestControl", if (inRoom) state?.guestControl ?: "all" else "all")
            .put("trimMs", trimMs)
            .put("video", video)
            .put("videoHeight", videoHeight)
            .put("solo", snap.solo)
            .put("soloItemId", snap.soloItemId ?: JSONObject.NULL)
            .put("queue", JSONArray().also { array -> (if (inRoom) state?.queue else local.queue)?.forEach { array.put(item(it)) } })
            .put(
                "members",
                JSONArray().also { array ->
                    snap.members.forEach {
                        array.put(
                            JSONObject()
                                .put("id", it.id)
                                .put("name", it.name)
                                .put("ready", it.ready)
                                .put("solo", it.solo)
                                .put("away", it.away)
                                .put("owner", it.owner),
                        )
                    }
                },
            )
            .toString()
    }

    /** Fast changing values: sent about once a second while the UI is visible. */
    fun position(view: GroupController.View, player: GroupController.PlayerInfo): String =
        JSONObject()
            .put("type", "position")
            .put("playing", player.playing)
            .put("buffering", player.buffering)
            .put("positionMs", player.positionMs)
            .put("durationMs", player.durationMs)
            .put("driftMs", view.snapshot.driftMs ?: JSONObject.NULL)
            .put("speed", view.snapshot.speed.toDouble())
            .put("videoWidth", player.videoWidth)
            .put("videoHeight", player.videoHeight)
            .toString()

    /** An invitation link was opened: the UI offers to join that room. */
    fun invite(code: String): String = JSONObject().put("type", "invite").put("code", code).toString()

    /** Another member paused the room or skipped a song; [by] is their name. */
    fun notice(notice: GroupController.Notice): String = JSONObject()
        .put("type", "notice")
        .put("kind", notice.kind)
        .put("by", notice.by)
        .put("title", notice.title ?: JSONObject.NULL)
        .toString()

    fun error(code: String, message: String): String =
        JSONObject().put("type", "error").put("code", code).put("message", message).toString()

    fun item(item: QueueItem): JSONObject = JSONObject()
        .put("id", item.id)
        .put("videoId", item.videoId)
        .put("title", item.title)
        .put("artist", item.artist)
        .put("thumb", item.thumb ?: JSONObject.NULL)
        .put("durMs", item.durMs)
        .put("addedBy", item.addedBy)

    private fun connectionName(view: GroupController.View): String = when (view.connection) {
        null -> "none"
        Connection.CONNECTING -> "connecting"
        Connection.CONNECTED -> "connected"
        Connection.RECONNECTING -> "reconnecting"
        Connection.CLOSED -> "closed"
        Connection.UNAUTHORIZED -> "unauthorized"
        Connection.REFUSED -> "closed"
    }
}
