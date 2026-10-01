import Foundation

// Wire protocol with the room server. Mirrors server/src/protocol.ts and docs/PROTOCOL.md.

struct QueueItem: Equatable, Codable {
    var id: String
    var videoId: String
    var title: String
    var artist: String
    var thumb: String?
    var durMs: Int64
    var addedBy: String

    init(id: String, videoId: String, title: String, artist: String, thumb: String?, durMs: Int64, addedBy: String) {
        self.id = id
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.thumb = thumb
        self.durMs = durMs
        self.addedBy = addedBy
    }

    init?(_ json: JSON) {
        guard let id = json["id"].string, let videoId = json["videoId"].string, let title = json["title"].string else { return nil }
        self.init(
            id: id,
            videoId: videoId,
            title: title,
            artist: json["artist"].string ?? "",
            thumb: json["thumb"].string,
            durMs: json["durMs"].int64 ?? 0,
            addedBy: json["addedBy"].string ?? ""
        )
    }
}

/// A song to put on the queue; the server adds the item id and who added it.
struct TrackRef: Equatable {
    var videoId: String
    var title: String
    var artist: String
    var thumb: String?
    var durMs: Int64

    init(videoId: String, title: String, artist: String, thumb: String?, durMs: Int64) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.thumb = thumb
        self.durMs = durMs
    }

    /// A song as the UI sends it.
    init?(map: [String: Any]) {
        guard let videoId = map["videoId"] as? String, let title = map["title"] as? String else { return nil }
        self.init(
            videoId: videoId,
            title: title,
            artist: map["artist"] as? String ?? "",
            thumb: map["thumb"] as? String,
            durMs: JSON(map["durMs"]).int64 ?? 0
        )
    }

    func toMap() -> [String: Any] {
        ["videoId": videoId, "title": title, "artist": artist, "thumb": thumb ?? NSNull(), "durMs": durMs]
    }
}

/// Room state as broadcast by the server. [phase] is one of idle, preparing, playing, paused.
struct RoomState: Equatable {
    var queue: [QueueItem]
    var index: Int
    var phase: String
    /// Server time at which position 0 of the current item is played. Valid while playing.
    var startedAt: Int64
    /// Position in the current item; authoritative while paused or preparing.
    var positionMs: Int64
    var epoch: Int64
    /// What happens when an item ends: off (stop after the queue), all (start over) or one (same item).
    var repeatMode: String = "off"
    /// Room name; nil when the room has none (or the server is older).
    var name: String?
    /// Client id of the owner; nil while the room has none.
    var ownerId: String?
    /// While the owner is here: `all` lets every member control the room, `add` lets guests only add songs.
    var guestControl: String = "all"

    var current: QueueItem? { queue.indices.contains(index) ? queue[index] : nil }

    init(queue: [QueueItem], index: Int, phase: String, startedAt: Int64, positionMs: Int64, epoch: Int64,
         repeatMode: String = "off", name: String? = nil, ownerId: String? = nil, guestControl: String = "all") {
        self.queue = queue
        self.index = index
        self.phase = phase
        self.startedAt = startedAt
        self.positionMs = positionMs
        self.epoch = epoch
        self.repeatMode = repeatMode
        self.name = name
        self.ownerId = ownerId
        self.guestControl = guestControl
    }

    init?(_ json: JSON) {
        guard let phase = json["phase"].string, let index = json["index"].int, let epoch = json["epoch"].int64 else { return nil }
        self.init(
            queue: json["queue"].array.compactMap { QueueItem($0) },
            index: index,
            phase: phase,
            startedAt: json["startedAt"].int64 ?? 0,
            positionMs: json["positionMs"].int64 ?? 0,
            epoch: epoch,
            repeatMode: json["repeat"].string ?? "off",
            name: json["name"].string,
            ownerId: json["ownerId"].string,
            guestControl: json["guestControl"].string ?? "all"
        )
    }
}

struct Member: Equatable {
    var id: String
    var name: String
    var ready: Bool
    /// Listening on their own: the room's play, pause and skip do not move this device.
    var solo: Bool = false
    /// Not heard from for a while, probably a dead connection: not counted as listening.
    var away: Bool = false
    /// Can change the room's settings and remove people.
    var owner: Bool = false

    init(id: String, name: String, ready: Bool, solo: Bool = false, away: Bool = false, owner: Bool = false) {
        self.id = id
        self.name = name
        self.ready = ready
        self.solo = solo
        self.away = away
        self.owner = owner
    }

    init?(_ json: JSON) {
        guard let id = json["id"].string, let name = json["name"].string else { return nil }
        self.init(
            id: id,
            name: name,
            ready: json["ready"].bool ?? false,
            solo: json["solo"].bool ?? false,
            away: json["away"].bool ?? false,
            owner: json["owner"].bool ?? false
        )
    }
}

enum ServerMessage: Equatable {
    case state(serverNow: Int64, you: String, state: RoomState, members: [Member], protocolVersion: Int)
    case members([Member])
    /// [by] is the client id of whoever asked for it; nil when the room moved on by itself.
    case prepare(epoch: Int64, index: Int, item: QueueItem, seekToMs: Int64, by: String?)
    /// Play so that position [positionMs] is heard at server time [startAt].
    case start(epoch: Int64, startAt: Int64, positionMs: Int64, by: String?)
    case pause(epoch: Int64, positionMs: Int64, by: String?)
    /// The room moved on to the item at [index]; position 0 of it was heard at server time [startedAt].
    case advance(epoch: Int64, index: Int, startedAt: Int64)
    case pong(c0: Int64, s1: Int64)
    case error(code: String, message: String)
}

enum Wire {
    /// Returns nil for anything that is not a well-formed message we understand.
    static func parse(_ text: String) -> ServerMessage? {
        guard let json = JSON.parse(text), json.object != nil, let kind = json["t"].string else { return nil }
        switch kind {
        case "state":
            guard let serverNow = json["serverNow"].int64, let you = json["you"].string, let state = RoomState(json["state"]) else { return nil }
            return .state(
                serverNow: serverNow,
                you: you,
                state: state,
                members: json["members"].array.compactMap { Member($0) },
                protocolVersion: json["protocol"].int ?? 0
            )
        case "members":
            return .members(json["members"].array.compactMap { Member($0) })
        case "prepare":
            guard let epoch = json["epoch"].int64, let index = json["index"].int, let item = QueueItem(json["item"]),
                  let seek = json["seekToMs"].int64 else { return nil }
            return .prepare(epoch: epoch, index: index, item: item, seekToMs: seek, by: json["by"].string)
        case "start":
            guard let epoch = json["epoch"].int64, let startAt = json["startAt"].int64, let position = json["positionMs"].int64 else { return nil }
            return .start(epoch: epoch, startAt: startAt, positionMs: position, by: json["by"].string)
        case "pause":
            guard let epoch = json["epoch"].int64, let position = json["positionMs"].int64 else { return nil }
            return .pause(epoch: epoch, positionMs: position, by: json["by"].string)
        case "advance":
            guard let epoch = json["epoch"].int64, let index = json["index"].int, let startedAt = json["startedAt"].int64 else { return nil }
            return .advance(epoch: epoch, index: index, startedAt: startedAt)
        case "pong":
            guard let c0 = json["c0"].int64, let s1 = json["s1"].int64 else { return nil }
            return .pong(c0: c0, s1: s1)
        case "error":
            guard let code = json["code"].string, let message = json["message"].string else { return nil }
            return .error(code: code, message: message)
        default:
            return nil
        }
    }

    // ---- client -> server ----

    /// [create] says what the device expects: true for a code it just made, false for one it was given, so
    /// that a mistyped code is refused instead of opening an empty room. nil leaves it out, as older apps do.
    static func join(clientId: String, name: String, create: Bool? = nil) -> String {
        msg("join", ["clientId": clientId, "name": name], optional: create.map { ["create": $0] })
    }

    /// Leaving on purpose, as opposed to a connection that dropped.
    static func bye() -> String { msg("bye") }

    /// Owner only: disconnect a member.
    static func kick(_ id: String) -> String { msg("kick", ["id": id]) }

    static func roomName(_ name: String) -> String { msg("room.name", ["name": name]) }

    /// Owner only: `all` or `add`.
    static func roomSettings(guestControl: String) -> String { msg("room.settings", ["guestControl": guestControl]) }

    static func ping(_ c0: Int64) -> String { msg("ping", ["c0": c0]) }

    /// With [playNext] the track goes right after the current one instead of at the end.
    static func queueAdd(_ track: TrackRef, playNext: Bool = false) -> String {
        var fields = trackFields(track)
        if playNext { fields["next"] = true }
        return msg("queue.add", fields)
    }

    /// A playlist in one message. With [playNext] the songs go right after the current one.
    static func queueAddMany(_ tracks: [TrackRef], playNext: Bool = false) -> String {
        var fields: [String: Any] = ["tracks": tracks.map { trackFields($0) }]
        if playNext { fields["next"] = true }
        return msg("queue.addMany", fields)
    }

    static func repeatMode(_ mode: String) -> String { msg("repeat", ["mode": mode]) }

    static func queueRemove(_ id: String) -> String { msg("queue.remove", ["id": id]) }

    /// Put [track], another release of the same song, in place of queue item [id].
    static func queueSwap(_ id: String, _ track: TrackRef) -> String {
        msg("queue.swap", ["id": id, "track": trackFields(track)])
    }

    static func queueClear() -> String { msg("queue.clear") }

    /// Mix up the songs still to come; with nothing playing, mix them all and play from the first.
    static func queueShuffle() -> String { msg("queue.shuffle") }

    /// Move queue item [id] so that it ends up at [toIndex].
    static func queueMove(_ id: String, toIndex: Int) -> String { msg("queue.move", ["id": id, "toIndex": toIndex]) }

    /// Start playing the queue item [id] from the beginning.
    static func jump(_ id: String) -> String { msg("jump", ["id": id]) }

    static func play() -> String { msg("play") }
    static func pause() -> String { msg("pause") }
    static func seek(_ positionMs: Int64) -> String { msg("seek", ["positionMs": positionMs]) }
    static func next() -> String { msg("next") }
    static func prev() -> String { msg("prev") }

    /// Start or stop listening on one's own; a solo device never holds the room back.
    static func solo(_ on: Bool) -> String { msg("solo", ["on": on]) }

    /// Ask for the room's current state again, as when rejoining after listening alone.
    static func resync() -> String { msg("resync") }

    static func ready(_ epoch: Int64) -> String { msg("ready", ["epoch": epoch]) }

    static func resolveFailed(_ epoch: Int64, reason: String?) -> String {
        var fields: [String: Any] = ["epoch": epoch]
        if let reason { fields["reason"] = String(reason.prefix(200)) }
        return msg("resolveFailed", fields)
    }

    static func ended(_ epoch: Int64) -> String { msg("ended", ["epoch": epoch]) }

    /// This device moved on to queue item [itemId] by itself; position 0 was heard at [startedAt] (server time).
    static func advanced(_ epoch: Int64, itemId: String, startedAt: Int64) -> String {
        msg("advanced", ["epoch": epoch, "itemId": itemId, "startedAt": startedAt])
    }

    private static func trackFields(_ track: TrackRef) -> [String: Any] {
        var fields: [String: Any] = ["videoId": track.videoId, "title": track.title, "artist": track.artist, "durMs": track.durMs]
        if let thumb = track.thumb { fields["thumb"] = thumb }
        return fields
    }

    private static func msg(_ t: String, _ fields: [String: Any] = [:], optional: [String: Any]? = nil) -> String {
        var object = fields
        object["t"] = t
        optional?.forEach { object[$0.key] = $0.value }
        return JSONText.encode(object)
    }
}
