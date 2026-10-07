import Foundation

/// JSON the Flutter UI receives. The keys are a contract with lib/data/models.dart.
enum UiJson {

    /// Structure of what is playing: the room, or outside one the personal queue in the same shape (no room code, no
    /// members). Changes rarely, so the UI only rebuilds when this differs.
    static func state(_ view: GroupController.View, trimMs: Int64, video: Bool = false, videoHeight: Int = 720,
                      playbackSpeed: Float = 1) -> String {
        let snap = view.snapshot
        let state = snap.state
        let local = view.local
        let inRoom = view.roomCode != nil
        let queue = inRoom ? state?.queue ?? [] : local.queue
        // Outside a room whether it plays is the player's business; this only says whether there is something to play
        let phase = inRoom ? state?.phase ?? "idle" : (local.queue.isEmpty || local.finished ? "idle" : "paused")
        let object: [String: Any] = [
            "type": "state",
            "room": view.roomCode ?? NSNull(),
            "connection": connectionName(view),
            "you": snap.you ?? NSNull(),
            "phase": phase,
            "repeat": inRoom ? state?.repeatMode ?? "off" : local.repeatMode,
            "index": inRoom ? state?.index ?? 0 : local.index,
            "name": (inRoom ? state?.name : nil) ?? NSNull(),
            "ownerId": (inRoom ? state?.ownerId : nil) ?? NSNull(),
            "guestControl": inRoom ? state?.guestControl ?? "all" : "all",
            "roomAutoplay": (inRoom ? state?.autoplay : nil) ?? NSNull(),
            // Outside a room this device's own; in one the room's, or null on a server too old to have it
            "shuffle": (inRoom ? state?.shuffle : Optional(local.shuffle)) ?? NSNull(),
            "trimMs": trimMs,
            "video": video,
            "videoHeight": videoHeight,
            "playbackSpeed": Double(playbackSpeed),
            "solo": snap.solo,
            "soloItemId": snap.soloItemId ?? NSNull(),
            // A song is on its way to play on this device: outside a room, or while listening alone in one
            "loading": inRoom ? snap.loading : local.loading,
            "queue": queue.map(item),
            "members": snap.members.map {
                ["id": $0.id, "name": $0.name, "ready": $0.ready, "solo": $0.solo, "away": $0.away, "owner": $0.owner] as [String: Any]
            },
        ]
        return JSONText.encode(object)
    }

    /// The phone is warm or saving power ([on]): the screen should move less.
    static func calm(_ on: Bool) -> String { JSONText.encode(["type": "calm", "on": on]) }

    /// The volume of the device, 0 to 1.
    static func volume(_ level: Float) -> String { JSONText.encode(["type": "volume", "level": Double(level)]) }

    /// Where the sound goes now; see [AudioOutput].
    static func output(_ output: AudioOutput) -> String {
        JSONText.encode(["type": "output", "kind": output.kind, "name": output.name])
    }

    /// A member's picture as base64, or none; the screen keeps it by the member's id.
    static func avatar(_ avatar: GroupController.Avatar) -> String {
        JSONText.encode(["type": "avatar", "id": avatar.id, "data": avatar.data ?? NSNull()] as [String: Any])
    }

    /// Chat messages of `chat.room`: all of them when `replace`, else new ones.
    static func chat(_ chat: GroupController.Chat) -> String {
        JSONText.encode([
            "type": "chat",
            "room": chat.room,
            "replace": chat.replace,
            "messages": chat.messages.map { message -> [String: Any] in
                ["id": message.id, "by": message.by, "name": message.name, "text": message.text, "at": message.at,
                 "cid": message.cid ?? NSNull()]
            },
        ] as [String: Any])
    }

    /// Another member reacted.
    static func reaction(_ reaction: GroupController.Reaction) -> String {
        JSONText.encode(["type": "reaction", "by": reaction.by, "e": reaction.e, "n": reaction.n] as [String: Any])
    }

    /// Another member reacted while the screen was off: the screen shows it as one that came late.
    static func reaction(_ missed: MissedReactions.Missed) -> String {
        JSONText.encode(["type": "reaction", "by": missed.by, "e": missed.e, "n": missed.n, "late": true] as [String: Any])
    }

    /// Fast changing values: sent about once a second while the UI is visible.
    static func position(_ view: GroupController.View, _ player: PlayerInfo) -> String {
        JSONText.encode([
            "type": "position",
            "playing": player.playing,
            "buffering": player.buffering,
            "positionMs": player.positionMs,
            "durationMs": player.durationMs,
            "driftMs": view.snapshot.driftMs ?? NSNull(),
            "speed": Double(player.speed),
            "videoWidth": player.videoWidth,
            "videoHeight": player.videoHeight,
            "noPicture": player.noPicture,
            "heldBack": player.heldBack,
        ] as [String: Any])
    }

    /// The sleep timer was set, ran out or was turned off.
    static func sleep(_ sleep: Sleep) -> String {
        switch sleep {
        case let .at(endsAtMs): return JSONText.encode(["type": "sleep", "mode": "time", "endsAt": endsAtMs] as [String: Any])
        case .songEnd: return JSONText.encode(["type": "sleep", "mode": "song", "endsAt": NSNull()] as [String: Any])
        case .off: return JSONText.encode(["type": "sleep", "mode": "off", "endsAt": NSNull()] as [String: Any])
        }
    }

    /// Liked songs or the history changed: the UI reads them again.
    static func library() -> String { JSONText.encode(["type": "library"]) }

    /// An invitation link was opened: the UI offers to join that room.
    static func invite(_ code: String) -> String { JSONText.encode(["type": "invite", "code": code]) }

    /// A setup link was opened: the address and key of the server, to be used if the person agrees.
    static func setup(_ link: String) -> String { JSONText.encode(["type": "setup", "link": link]) }

    /// Another member paused the room or skipped a song; [by] is their name.
    static func notice(_ notice: GroupController.Notice) -> String {
        JSONText.encode(["type": "notice", "kind": notice.kind, "by": notice.by, "title": notice.title ?? NSNull()] as [String: Any])
    }

    static func error(code: String, message: String) -> String {
        JSONText.encode(["type": "error", "code": code, "message": message])
    }

    static func item(_ item: QueueItem) -> [String: Any] {
        [
            "id": item.id, "videoId": item.videoId, "title": item.title, "artist": item.artist,
            "thumb": item.thumb ?? NSNull(), "durMs": item.durMs, "addedBy": item.addedBy,
        ]
    }

    private static func connectionName(_ view: GroupController.View) -> String {
        guard let connection = view.connection else { return "none" }
        switch connection {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting"
        case .closed, .refused: return "closed"
        case .unauthorized: return "unauthorized"
        }
    }
}

/// What the full player shows, in the shape the UI reads it (plain maps for the platform channel).
enum MusicJson {
    static func track(_ track: MusicTrack) -> [String: Any] {
        [
            "videoId": track.videoId, "title": track.title, "artist": track.artist, "artistId": track.artistId ?? NSNull(),
            "album": track.album ?? NSNull(), "albumId": track.albumId ?? NSNull(), "year": track.year ?? NSNull(),
            "thumb": track.thumbUrl ?? NSNull(), "durMs": track.durationSec * 1000, "isSong": track.isSong,
            "stats": track.stats ?? NSNull(),
        ]
    }

    static func next(_ next: WatchNext) -> [String: Any] {
        ["tracks": next.tracks.map(track), "hasLyrics": next.lyricsId != nil, "hasRelated": next.relatedId != nil]
    }

    static func related(_ related: Related?) -> [String: Any] {
        [
            "more": (related?.more ?? []).map(track),
            "otherPerformances": (related?.otherPerformances ?? []).map(track),
            "artists": (related?.artists ?? []).map(artistCard),
            "playlists": (related?.playlists ?? []).map(playlistCard),
            "about": related?.about ?? NSNull(),
        ]
    }

    static func artist(_ page: ArtistPage) -> [String: Any] {
        [
            "id": page.id, "name": page.name, "description": page.description ?? NSNull(), "subscribers": page.subscribers ?? NSNull(),
            "thumb": page.thumbUrl ?? NSNull(), "topSongs": page.topSongs.map(track),
            "albums": page.albums.map(albumCard), "singles": page.singles.map(albumCard),
            "similar": page.similar.map(artistCard),
            "shelves": shelves(page.shelves), "topSongsId": page.topSongsId ?? NSNull(),
        ]
    }

    static func collection(_ page: CollectionPage) -> [String: Any] {
        [
            "id": page.id, "title": page.title, "kind": page.kind ?? NSNull(), "year": page.year ?? NSNull(),
            "owner": page.owner ?? NSNull(), "ownerId": page.ownerId ?? NSNull(), "description": page.description ?? NSNull(),
            "thumb": page.thumbUrl ?? NSNull(), "stats": page.stats, "tracks": page.tracks.map(track),
            "more": page.more ?? NSNull(), "shelves": shelves(page.shelves),
        ]
    }

    static func searchPage(_ page: SearchPage) -> [String: Any] {
        [
            "chips": page.chips.map { ["label": $0.label, "params": $0.params] },
            "top": page.top.map(searchItem) ?? NSNull(),
            "items": page.items.map(searchItem),
            "more": page.more ?? NSNull(),
        ]
    }

    private static func searchItem(_ item: SearchItem) -> [String: Any] {
        [
            "kind": item.kind, "id": item.id, "title": item.title, "subtitle": item.subtitle ?? NSNull(),
            "label": item.label ?? NSNull(), "thumb": item.thumbUrl ?? NSNull(), "track": item.track.map(track) ?? NSNull(),
        ]
    }

    static func continuation(_ next: Continuation) -> [String: Any] {
        ["tracks": next.tracks.map(track), "more": next.more ?? NSNull()]
    }

    /// Times in whole milliseconds, one pair per line; with no times the lines are empty and only the plain text is there.
    static func lyrics(_ lyrics: Lyrics?) -> [String: Any]? {
        guard let lyrics else { return nil }
        return ["synced": lyrics.synced, "lines": lyrics.lines.map { [$0.ms, $0.text] as [Any] }, "plain": lyrics.plain ?? NSNull()]
    }

    static func shelves(_ shelves: [MusicShelf]) -> [[String: Any]] {
        shelves.map {
            [
                "title": $0.title, "tracks": $0.tracks.map(track), "playlists": $0.playlists.map(playlistCard),
                "albums": $0.albums.map(albumCard), "artists": $0.artists.map(artistCard),
            ] as [String: Any]
        }
    }

    private static func artistCard(_ card: ArtistCard) -> [String: Any] {
        ["id": card.id, "name": card.name, "subtitle": card.subtitle ?? NSNull(), "thumb": card.thumbUrl ?? NSNull()]
    }

    private static func albumCard(_ card: AlbumCard) -> [String: Any] {
        ["id": card.id, "title": card.title, "subtitle": card.subtitle ?? NSNull(), "thumb": card.thumbUrl ?? NSNull()]
    }

    private static func playlistCard(_ card: PlaylistCard) -> [String: Any] {
        ["id": card.id, "title": card.title, "subtitle": card.subtitle ?? NSNull(), "thumb": card.thumbUrl ?? NSNull()]
    }
}
