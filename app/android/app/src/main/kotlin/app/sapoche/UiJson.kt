package app.sapoche

import app.sapoche.sync.Connection
import app.sapoche.sync.MissedReactions
import app.sapoche.sync.QueueItem
import app.sapoche.sync.Sleep
import org.json.JSONArray
import org.json.JSONObject

/** JSON the Flutter UI receives. The keys are a contract with lib/data/models.dart. */
object UiJson {

    /**
     * Structure of what is playing: the room, or outside one the personal queue in the same shape (no
     * room code, no members). Changes rarely, so the UI only rebuilds when this differs.
     */
    fun state(view: GroupController.View, trimMs: Long, video: Boolean = false, videoHeight: Int = 720, playbackSpeed: Float = 1f): String {
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
            .put("roomAutoplay", state?.autoplay.takeIf { inRoom } ?: JSONObject.NULL)
            // Outside a room this device's own; in one the room's, or null on a server too old to have it
            .put("shuffle", if (inRoom) state?.shuffle ?: JSONObject.NULL else local.shuffle)
            .put("trimMs", trimMs)
            .put("video", video)
            .put("videoHeight", videoHeight)
            .put("playbackSpeed", playbackSpeed.toDouble())
            .put("solo", snap.solo)
            .put("soloItemId", snap.soloItemId ?: JSONObject.NULL)
            // A song is on its way to play on this device: outside a room, or while listening alone in one
            .put("loading", if (inRoom) snap.loading else local.loading)
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

    /** The phone is warm or saving power ([on]): the screen should move less. */
    fun calm(on: Boolean): String = JSONObject().put("type", "calm").put("on", on).toString()

    /** The volume of the music, 0 to 1. */
    fun volume(level: Float): String = JSONObject().put("type", "volume").put("level", level.toDouble()).toString()

    /** Where the sound goes now; see [AudioOutput]. */
    fun output(output: AudioOutput): String =
        JSONObject().put("type", "output").put("kind", output.kind).put("name", output.name).toString()

    /** Where an update of the app stands; see [Updater]. */
    fun update(state: UpdateState): String {
        val release = state.release
        return JSONObject()
            .put("type", "update")
            // The names are the ones lib/data/update_info.dart knows (camelCase), not the enum's own
            .put(
                "phase",
                when (state.phase) {
                    UpdateState.Phase.IDLE -> "idle"
                    UpdateState.Phase.CHECKING -> "checking"
                    UpdateState.Phase.UP_TO_DATE -> "upToDate"
                    UpdateState.Phase.AVAILABLE -> "available"
                    UpdateState.Phase.DOWNLOADING -> "downloading"
                    UpdateState.Phase.READY -> "ready"
                    UpdateState.Phase.NEEDS_PERMISSION -> "needsPermission"
                    UpdateState.Phase.INSTALLING -> "installing"
                    UpdateState.Phase.FAILED -> "failed"
                },
            )
            .put("installed", state.installed)
            .put("version", release?.versionName ?: JSONObject.NULL)
            // In the language the app speaks, when the release has its notes in it
            .put("notes", release?.let { if (SapocheApp.language.value == "vi" && it.notesVi.isNotBlank()) it.notesVi else it.notes } ?: JSONObject.NULL)
            .put("size", release?.size ?: 0L)
            .put("done", state.doneBytes)
            .put("error", state.error ?: JSONObject.NULL)
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
            .put("speed", player.speed.toDouble())
            .put("videoWidth", player.videoWidth)
            .put("videoHeight", player.videoHeight)
            .put("noPicture", player.noPicture)
            .put("heldBack", player.heldBack)
            .toString()

    /** The sleep timer was set, ran out or was turned off. */
    fun sleep(sleep: Sleep): String = JSONObject()
        .put("type", "sleep")
        .put("mode", if (sleep is Sleep.At) "time" else if (sleep == Sleep.SongEnd) "song" else "off")
        .put("endsAt", if (sleep is Sleep.At) sleep.endsAtMs else JSONObject.NULL)
        .toString()

    /** Liked songs or the history changed: the UI reads them again. */
    fun library(): String = JSONObject().put("type", "library").toString()

    /** An invitation link was opened: the UI offers to join that room. */
    /** A member's picture as base64, or none; the screen keeps it by the member's id. */
    fun avatar(avatar: GroupController.Avatar): String =
        JSONObject().put("type", "avatar").put("id", avatar.id).put("data", avatar.data ?: JSONObject.NULL).toString()

    /** Chat messages of [GroupController.Chat.room]: all of them when `replace`, else new ones. */
    fun chat(chat: GroupController.Chat): String = JSONObject()
        .put("type", "chat")
        .put("room", chat.room)
        .put("replace", chat.replace)
        .put(
            "messages",
            JSONArray(chat.messages.map {
                JSONObject()
                    .put("id", it.id)
                    .put("by", it.by)
                    .put("name", it.name)
                    .put("text", it.text)
                    .put("at", it.at)
                    .put("cid", it.cid ?: JSONObject.NULL)
            }),
        )
        .toString()

    /** Another member reacted. */
    fun reaction(reaction: GroupController.Reaction): String =
        JSONObject().put("type", "reaction").put("by", reaction.by).put("e", reaction.e).put("n", reaction.n).toString()

    /** Another member reacted while the screen was off: the screen shows it as one that came late. */
    fun reaction(missed: MissedReactions.Missed): String =
        JSONObject()
            .put("type", "reaction")
            .put("by", missed.by)
            .put("e", missed.e)
            .put("n", missed.n)
            .put("late", true)
            .toString()

    /** The app went into a small window over other apps ([on]), or came back out of it. */
    fun pip(on: Boolean): String = JSONObject().put("type", "pip").put("on", on).toString()

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
