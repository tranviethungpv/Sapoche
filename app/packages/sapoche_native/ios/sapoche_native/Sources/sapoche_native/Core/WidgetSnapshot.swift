import Foundation

/// What the widgets of the home screen, the lock screen and the Live Activity show: the song, whether it plays and, in a
/// room, where. The app writes it into a folder it shares with the widgets (an App Group) whenever it changes; a widget
/// is drawn from it alone, so it works while the app is not running.
///
/// This file is also compiled into the widgets' own target, so it uses nothing but Foundation.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// A song that comes after the one playing; [by] is the name of who added it, in a room.
    public struct Row: Codable, Equatable, Sendable {
        public var title: String
        public var artist: String
        public var by: String?

        public init(title: String, artist: String, by: String? = nil) {
            self.title = title
            self.artist = artist
            self.by = by
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

    public static let nextRows = 3

    public init(
        title: String = "", artist: String = "", playing: Bool = false, room: String? = nil, roomCode: String? = nil,
        crew: [String] = [], next: [Row] = [], canSteer: Bool = true, startedAt: Date? = nil, endsAt: Date? = nil,
        updatedAt: Date = Date()
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

/// The folder the app shares with its widgets, and the files in it.
public struct WidgetStorage {
    public static let snapshotFile = "widget.json"
    public static let coverFile = "widget_cover.jpg"

    /// The App Group the widgets and the app share. SideStore gives each phone's copy its own group name and says it in the
    /// `ALTAppGroups` list of the Info.plist; a build for a developer account uses the name given here.
    public static let defaultGroup = "group.app.sapoche.sapoche"

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// The shared folder of this app (or widget), or nil when the system did not give it one: then nothing is shared.
    public static func shared(bundle: Bundle = .main) -> WidgetStorage? {
        #if canImport(Darwin)
        let groups = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
        let name = groups?.first ?? defaultGroup
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: name) else { return nil }
        return WidgetStorage(folder: url)
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
