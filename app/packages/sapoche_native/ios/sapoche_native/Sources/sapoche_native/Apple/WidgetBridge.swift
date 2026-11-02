import Foundation
import UIKit
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(ActivityKit)
import ActivityKit
#endif

/// What a button of a widget, the lock screen or Control Center asks of the app. The buttons are App Intents of the app
/// target (which cannot see this module), so they say it through a notification and, for the app that is not running yet,
/// a note in the defaults, like a link that opens the app does.
enum WidgetCommand: String {
    case playPause
    case next
    case previous
}

/// Keeps the widgets and the Live Activity in step with what plays, and hears their buttons.
@MainActor
final class WidgetBridge {
    static let commandNotification = Notification.Name("app.sapoche.widgetCommand")
    static let pendingCommandKey = "sapoche.pendingWidgetCommand"

    private let storage = WidgetStorage.shared()
    private var observer: NSObjectProtocol?
    private var last: WidgetSnapshot?
    private var lastCover: String?
    private var lastCoverWritten: String?
    private var activity: Any?

    /// Starts listening for the widgets' buttons; [handle] is what each one does.
    func start(handle: @escaping (WidgetCommand) -> Void) {
        let pendingKey = Self.pendingCommandKey
        observer = NotificationCenter.default.addObserver(forName: Self.commandNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?["command"] as? String, let command = WidgetCommand(rawValue: raw) else { return }
            // Heard now, so it is not to be heard again at the next start
            UserDefaults.standard.removeObject(forKey: pendingKey)
            Task { @MainActor in handle(command) }
        }
        // A button that started the app: it asked before anybody listened
        if let raw = UserDefaults.standard.string(forKey: Self.pendingCommandKey), let command = WidgetCommand(rawValue: raw) {
            UserDefaults.standard.removeObject(forKey: Self.pendingCommandKey)
            handle(command)
        }
    }

    /// Writes what is shown now where the widgets read it and has them drawn again when it changed. [cover] is the picture
    /// of the song as a small JPEG, given when it is a new one.
    func publish(_ snapshot: WidgetSnapshot, coverFor videoId: String?, cover: @autoclosure () -> Data?) {
        guard let storage else { return }
        if let videoId, videoId != lastCover {
            if let data = cover() {
                storage.writeCover(data)
                lastCover = videoId
            }
        } else if videoId == nil, lastCover != nil {
            storage.writeCover(nil)
            lastCover = nil
        }
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
