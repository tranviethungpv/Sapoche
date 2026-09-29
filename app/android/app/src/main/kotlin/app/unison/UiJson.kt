package app.unison

import app.unison.sync.Connection
import app.unison.sync.QueueItem
import org.json.JSONArray
import org.json.JSONObject

/** JSON the Flutter UI receives. The keys are a contract with lib/data/models.dart. */
object UiJson {

    /** Structure of the room. Changes rarely, so the UI only rebuilds when this differs. */
    fun state(view: GroupController.View, trimMs: Long): String {
        val snap = view.snapshot
        val state = snap.state
        return JSONObject()
            .put("type", "state")
            .put("room", view.roomCode ?: JSONObject.NULL)
            .put("connection", connectionName(view))
            .put("you", snap.you ?: JSONObject.NULL)
            .put("phase", state?.phase ?: "idle")
            .put("repeat", state?.repeat ?: "off")
            .put("index", state?.index ?: 0)
            .put("trimMs", trimMs)
            .put("queue", JSONArray().also { array -> state?.queue?.forEach { array.put(item(it)) } })
            .put(
                "members",
                JSONArray().also { array ->
                    snap.members.forEach {
                        array.put(JSONObject().put("id", it.id).put("name", it.name).put("ready", it.ready))
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
            .toString()

    /** An invitation link was opened: the UI offers to join that room. */
    fun invite(code: String): String = JSONObject().put("type", "invite").put("code", code).toString()

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
    }
}
