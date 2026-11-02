import AppIntents
import Foundation

/// How a button of a widget, of the lock screen or of Control Center reaches the app: a note in the defaults (for the app
/// that is not running yet) and a notification (for the one that is), which the app's native side listens to. This file is
/// in the app's target and in the widgets' target: the system looks for the intents of an audio button in the app, and
/// runs them there.
enum SapocheCommand {
    static func send(_ name: String) {
        UserDefaults.standard.set(name, forKey: "sapoche.pendingWidgetCommand")
        NotificationCenter.default.post(name: Notification.Name("app.sapoche.widgetCommand"), object: nil, userInfo: ["command": name])
    }

    /// A link that opens the app as `sapoche://join/CODE` does.
    static func open(_ link: String) {
        UserDefaults.standard.set(link, forKey: "sapoche.pendingURL")
        if let url = URL(string: link) {
            NotificationCenter.default.post(name: Notification.Name("app.sapoche.openURL"), object: url)
        }
    }
}

@available(iOS 17.0, *)
struct PlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or pause"
    static let description = IntentDescription("Plays or pauses what Sapoche is playing.")

    func perform() async throws -> some IntentResult {
        SapocheCommand.send("playPause")
        return .result()
    }
}

@available(iOS 17.0, *)
struct NextIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next song"

    func perform() async throws -> some IntentResult {
        SapocheCommand.send("next")
        return .result()
    }
}

@available(iOS 17.0, *)
struct PreviousIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous song"

    func perform() async throws -> some IntentResult {
        SapocheCommand.send("previous")
        return .result()
    }
}

/// A touch on a song of the queue shown by the large widget: the player jumps to it.
@available(iOS 17.0, *)
struct JumpIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play this song"

    @Parameter(title: "Song")
    var itemId: String

    init() {}

    init(itemId: String) {
        self.itemId = itemId
    }

    func perform() async throws -> some IntentResult {
        SapocheCommand.send("jump:\(itemId)")
        return .result()
    }
}

/// A tile of the quick widget: `liked`, `mix`, `downloads`, or `playlist` with the playlist's id.
@available(iOS 17.0, *)
struct QuickPlayIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a list"

    @Parameter(title: "List")
    var list: String

    @Parameter(title: "Playlist")
    var playlist: Int

    init() {}

    init(list: String, playlist: Int = 0) {
        self.list = list
        self.playlist = playlist
    }

    func perform() async throws -> some IntentResult {
        SapocheCommand.send(list == "playlist" ? "quick:playlist:\(playlist)" : "quick:\(list)")
        return .result()
    }
}

/// Opens the app, on the room this device is in when there is one.
@available(iOS 17.0, *)
struct OpenRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the room"
    static let openAppWhenRun = true

    @Parameter(title: "Room code")
    var code: String?

    init() {}

    init(code: String?) {
        self.code = code
    }

    func perform() async throws -> some IntentResult {
        if let code, !code.isEmpty { SapocheCommand.open("sapoche://join/\(code)") }
        return .result()
    }
}
