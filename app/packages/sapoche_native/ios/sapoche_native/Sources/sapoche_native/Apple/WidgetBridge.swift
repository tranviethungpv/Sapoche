import Foundation
import UIKit
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(ActivityKit)
import ActivityKit
#endif

/// What the widgets show besides the song, which only the rest of the app knows.
struct WidgetSources {
    /// The language of the app, `vi` or `en`.
    var language: () -> String
    /// The recent rooms as the app's screens keep them (`recent_rooms`, JSON), and what the server says of a room.
    var recentRooms: () -> String?
    var roomInfo: (String) async -> [String: Any]?
    var latestPlaylist: () async -> WidgetSnapshot.QuickPlaylist?
}

/// Keeps the widgets and the Live Activity in step with what plays, and hears their buttons.
@MainActor
final class WidgetBridge {
    static let commandNotification = Notification.Name("app.sapoche.widgetCommand")
    static let pendingCommandKey = "sapoche.pendingWidgetCommand"

    private let storage = WidgetStorage.shared()
    private var sources: WidgetSources?
    private var observer: NSObjectProtocol?
    private var base = WidgetSnapshot()
    private var last: WidgetSnapshot?
    private var lastCover: String?
    private var lastCoverWritten: String?
    private var activity: Any?
    private var friends: WidgetSnapshot.Friends?
    private var playlist: WidgetSnapshot.QuickPlaylist?
    private var extrasAt: Date?
    private var extrasRoom: String?
    private var extrasTask: Task<Void, Never>?

    /// Starts listening for the widgets' buttons; [handle] is what each one does.
    func start(sources: WidgetSources, handle: @escaping (WidgetCommand) -> Void) {
        self.sources = sources
        // Without the shared folder the widgets never hear of the app: say so where it can be read
        if let storage {
            EventLog.d("widgets", "the shared folder is \(storage.group.isEmpty ? "found" : storage.group)")
        } else {
            EventLog.d("widgets", "no shared folder (App Group): the widgets cannot be fed")
        }
        let pendingKey = Self.pendingCommandKey
        observer = NotificationCenter.default.addObserver(forName: Self.commandNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?["command"] as? String, let command = WidgetCommand(raw) else { return }
            // Heard now, so it is not to be heard again at the next start
            UserDefaults.standard.removeObject(forKey: pendingKey)
            Task { @MainActor in handle(command) }
        }
        // A button that started the app: it asked before anybody listened
        if let raw = UserDefaults.standard.string(forKey: Self.pendingCommandKey), let command = WidgetCommand(raw) {
            UserDefaults.standard.removeObject(forKey: Self.pendingCommandKey)
            handle(command)
        }
    }

    /// Writes what is shown now where the widgets read it and has them drawn again when it changed. [cover] is the picture
    /// of the song as a small JPEG, given when it is a new one.
    func publish(_ snapshot: WidgetSnapshot, coverFor videoId: String?, cover: @autoclosure () -> Data?) {
        guard storage != nil else { return }
        base = snapshot
        if let videoId, videoId != lastCover {
            if let data = cover() {
                storage?.writeCover(data)
                lastCover = videoId
            }
        } else if videoId == nil, lastCover != nil {
            storage?.writeCover(nil)
            lastCover = nil
        }
        refreshExtras()
        write()
    }

    /// The song and room as last given, with what only the rest of the app knows added.
    private func write() {
        guard let storage else { return }
        var snapshot = base
        snapshot.friends = friends
        snapshot.playlist = playlist
        snapshot.language = sources?.language() ?? ""
        // Where the song is moves with the clock and the widgets count it by themselves: only a change of what is shown
        // (the song, play or pause, the room, the queue) is written and drawn
        if let last, last.shown == snapshot.shown, lastCoverWritten == lastCover { return }
        last = snapshot
        lastCoverWritten = lastCover
        storage.write(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Where friends listen and the playlist touched last: asked again when the room joined or left changes and at most every
    /// ten minutes otherwise, because the player tells of itself twice a second in a room and the server is not for that.
    private func refreshExtras() {
        guard let sources, extrasTask == nil else { return }
        let room = base.roomCode
        if let extrasAt, extrasRoom == room, Date().timeIntervalSince(extrasAt) < 600 { return }
        extrasAt = Date()
        extrasRoom = room
        extrasTask = Task { [weak self] in
            let rooms = WidgetSnapshot.Friends.recent(sources.recentRooms())
            var asked: [(code: String, name: String?, info: [String: Any]?)] = []
            for room in rooms.prefix(5) { asked.append((room.code, room.name, await sources.roomInfo(room.code))) }
            let playlist = await sources.latestPlaylist()
            guard let self else { return }
            self.friends = WidgetSnapshot.Friends.choose(asked)
            self.playlist = playlist
            self.extrasTask = nil
            self.write()
        }
    }

    // ------------------------------------------------------------------ Live Activity of the room

    /// The room this device is in as a Live Activity (lock screen and Dynamic Island): started when a room is joined, updated
    /// with the song, ended when it is left. [room] is nil outside a room.
    func updateRoomActivity(room: (name: String, code: String)?, snapshot: WidgetSnapshot, members: Int) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        let existing = Activity<RoomActivityAttributes>.activities
        guard let room else {
            for old in existing { Task { await old.end(nil, dismissalPolicy: .immediate) } }
            activity = nil
            return
        }
        let state = RoomActivityAttributes.ContentState(
            title: snapshot.title, artist: snapshot.artist, playing: snapshot.playing, members: members,
            startedAt: snapshot.playing ? snapshot.startedAt : nil, endsAt: snapshot.playing ? snapshot.endsAt : nil
        )
        let content = ActivityContent(state: state, staleDate: nil)
        if let running = existing.first(where: { $0.attributes.roomCode == room.code }) {
            activity = running
            Task { await running.update(content) }
            return
        }
        // Another room's, or one the system kept from an earlier run
        for old in existing { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: RoomActivityAttributes(roomName: room.name, roomCode: room.code), content: content, pushType: nil)
        #endif
    }
}
