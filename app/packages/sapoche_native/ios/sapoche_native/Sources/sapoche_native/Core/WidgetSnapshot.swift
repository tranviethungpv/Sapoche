import Foundation

/// What the widgets of the home screen and the lock screen show: the song, whether it plays and, in a
/// room, where. The app writes it into a folder it shares with the widgets (an App Group) whenever it changes; a widget
/// is drawn from it alone, so it works while the app is not running.
///
/// This file is also compiled into the widgets' own target, so it uses nothing but Foundation.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// A song that comes after the one playing; [by] is the name of who added it, in a room, and [id] is its place in the
    /// queue, which a touch jumps to.
    public struct Row: Codable, Equatable, Sendable {
        public var title: String
        public var artist: String
        public var by: String?
        public var id: String?

        public init(title: String, artist: String, by: String? = nil, id: String? = nil) {
            self.title = title
            self.artist = artist
            self.by = by
            self.id = id
        }
    }

    /// The room worth showing when this device is in none: where friends are listening now, else the one it was in last.
    public struct Friends: Codable, Equatable, Sendable {
        public var code: String
        public var room: String
        public var who: [String]
        public var song: String?

        public init(code: String, room: String, who: [String] = [], song: String? = nil) {
            self.code = code
            self.room = room
            self.who = who
            self.song = song
        }

        /// The rooms this device has been in, from the list the app's screens keep: a JSON list of `{code, name, at}`, newest first.
        public static func recent(_ json: String?) -> [(code: String, name: String?)] {
            guard let data = json?.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
            return list.compactMap { entry in
                guard let code = entry["code"] as? String, !code.isEmpty else { return nil }
                return (code, (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
        }

        /// From the recent rooms and what the server says of each (nil: it could not be reached): the first room with somebody
        /// in it, else the first room the server still has. A room the server no longer has is left out.
        public static func choose(_ rooms: [(code: String, name: String?, info: [String: Any]?)]) -> Friends? {
            let found = rooms.filter { $0.info?["exists"] as? Bool == true }
            let pick = found.first { !(($0.info?["who"] as? [Any]) ?? []).isEmpty } ?? found.first
            guard let pick, let info = pick.info else { return nil }
            return Friends(
                code: pick.code, room: (info["name"] as? String) ?? pick.name ?? pick.code,
                who: ((info["who"] as? [Any]) ?? []).compactMap { $0 as? String }, song: info["title"] as? String
            )
        }
    }

    /// The playlist touched last, for the fourth tile of the quick widget.
    public struct QuickPlaylist: Codable, Equatable, Sendable {
        public var id: Int64
        public var name: String

        public init(id: Int64, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var title: String
    public var artist: String
    public var playing: Bool
    /// `Room name · 3` while joined to a room, else nil.
    public var room: String?
    /// The room's code, so that a touch can open it.
    public var roomCode: String?
    /// Names of up to three of the people listening, in a room.
    public var crew: [String]
    /// The next songs, at most [WidgetSnapshot.nextRows].
    public var next: [Row]
    /// This device may move the room (skip, seek): false for a guest of a room that only lets guests add songs.
    public var canSteer: Bool
    /// While it plays: when the song began and will end on the clock of this phone, which the system counts by itself.
    public var startedAt: Date?
    public var endsAt: Date?
    public var updatedAt: Date
    public var friends: Friends?
    public var playlist: QuickPlaylist?
    /// The language of the app (`vi` or `en`), which the widgets speak; empty when it was never written.
    public var language: String

    public static let nextRows = 3

    public init(
        title: String = "", artist: String = "", playing: Bool = false, room: String? = nil, roomCode: String? = nil,
        crew: [String] = [], next: [Row] = [], canSteer: Bool = true, startedAt: Date? = nil, endsAt: Date? = nil,
        updatedAt: Date = Date(), friends: Friends? = nil, playlist: QuickPlaylist? = nil, language: String = ""
    ) {
        self.title = title
        self.artist = artist
        self.playing = playing
        self.room = room
        self.roomCode = roomCode
        self.crew = crew
        self.next = Array(next.prefix(Self.nextRows))
        self.canSteer = canSteer
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.updatedAt = updatedAt
        self.friends = friends
        self.playlist = playlist
        self.language = language
    }

    /// Nothing is loaded: the widgets say so instead of showing an empty song.
    public var isIdle: Bool { title.isEmpty }

    /// The same thing shown, whatever time it was written at: what decides whether the widgets are drawn again.
    public var shown: WidgetSnapshot {
        var copy = self
        copy.updatedAt = Date(timeIntervalSince1970: 0)
        // Where the song is moves with the clock; the widgets count it by themselves, so a small shift is not news
        copy.startedAt = startedAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 2).rounded() * 2) }
        copy.endsAt = endsAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 2).rounded() * 2) }
        return copy
    }
}

/// What a button of a widget, the lock screen or Control Center asks of the app. The buttons are App Intents of the app
/// target (which cannot see this module), so they say it as text: through a notification and, for the app that is not
/// running yet, a note in the defaults.
public enum WidgetCommand: Equatable, Sendable {
    /// The lists a tile of the quick widget plays; [playlist] says which one when it is the playlist.
    public enum QuickList: String, Sendable {
        case liked, mix, downloads, playlist
    }

    case playPause
    case next
    case previous
    case jump(String)
    case quick(QuickList, playlist: Int64)

    public init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch (parts[0], parts.count) {
        case ("playPause", 1): self = .playPause
        case ("next", 1): self = .next
        case ("previous", 1): self = .previous
        case ("jump", 2...) where !parts[1].isEmpty:
            // An id may hold a colon itself
            self = .jump(parts.dropFirst().joined(separator: ":"))
        case ("quick", 2...):
            guard let list = QuickList(rawValue: parts[1]) else { return nil }
            if list == .playlist {
                guard parts.count == 3, let id = Int64(parts[2]) else { return nil }
                self = .quick(list, playlist: id)
            } else {
                self = .quick(list, playlist: 0)
            }
        default: return nil
        }
    }

    public var text: String {
        switch self {
        case .playPause: return "playPause"
        case .next: return "next"
        case .previous: return "previous"
        case .jump(let id): return "jump:\(id)"
        case .quick(let list, let playlist): return list == .playlist ? "quick:playlist:\(playlist)" : "quick:\(list.rawValue)"
        }
    }
}

/// The folder the app shares with its widgets, and the files in it.
public struct WidgetStorage {
    public static let snapshotFile = "widget.json"
    public static let coverFile = "widget_cover.jpg"

    /// The App Group the widgets and the app share. Signed with a developer account it is used as it is; SideStore gives each
    /// phone's copy the name with the id of its Apple ID's team after it (`group.app.sapoche.sapoche.ABCDE12345`), which
    /// [candidates] finds out from the profile the copy was signed with.
    public static let defaultGroup = "group.app.sapoche.sapoche"

    public let folder: URL
    /// The App Group the folder belongs to; empty when it was not found by name.
    public let group: String

    public init(folder: URL, group: String = "") {
        self.folder = folder
        self.group = group
    }

    /// The App Groups a signed copy was given, from the profile embedded in it (`embedded.mobileprovision`: a signed
    /// envelope around a property list).
    public static func groups(inProvision data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            return []
        }
        let list = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = (try? PropertyListSerialization.propertyList(from: list, options: [], format: nil)) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// The names to try for the shared folder, best first: the group of this app as the profile it was signed with names it,
    /// then what the Info.plist lists (`ALTAppGroups`), then the plain name.
    public static func candidates(provisioned: [String], listed: [String]) -> [String] {
        let ours = provisioned.filter { $0 == defaultGroup || $0.hasPrefix(defaultGroup + ".") }
        var seen = Set<String>()
        return (ours + listed + [defaultGroup]).filter { seen.insert($0).inserted }
    }

    /// The shared folder of this app (or widget), or nil when the system did not give it one: then nothing is shared.
    public static func shared(bundle: Bundle = .main) -> WidgetStorage? {
        #if canImport(Darwin)
        let provision = (try? Data(contentsOf: bundle.bundleURL.appendingPathComponent("embedded.mobileprovision"))).map(groups(inProvision:)) ?? []
        let listed = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        for name in candidates(provisioned: provision, listed: listed) {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: name) {
                return WidgetStorage(folder: url, group: name)
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    private var snapshotURL: URL { folder.appendingPathComponent(Self.snapshotFile) }
    private var coverURL: URL { folder.appendingPathComponent(Self.coverFile) }

    public func write(_ snapshot: WidgetSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// The picture of the song, as a small JPEG; nil takes it away.
    public func writeCover(_ jpeg: Data?) {
        if let jpeg { try? jpeg.write(to: coverURL, options: .atomic) } else { try? FileManager.default.removeItem(at: coverURL) }
    }

    public func cover() -> Data? {
        try? Data(contentsOf: coverURL)
    }
}
