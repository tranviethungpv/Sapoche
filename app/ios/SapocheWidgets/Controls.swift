import AppIntents
import SwiftUI
import WidgetKit

/// Buttons for Control Center and the lock screen (iOS 18 and later).
@available(iOS 18.0, *)
struct PlayPauseControl: ControlWidget {
    static let kind = "app.sapoche.control.playpause"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: PlayPauseIntent()) {
                Label(Language.t("Phát hoặc dừng", "Play or pause"), systemImage: "playpause.fill")
            }
        }
        .displayName(LocalizedStringResource(stringLiteral: Language.t("Phát hoặc dừng", "Play or pause")))
        .description(LocalizedStringResource(stringLiteral: Language.t("Phát hoặc dừng Sapoche.", "Plays or pauses Sapoche.")))
    }
}

/// Opens Sapoche on the room this device is in, if there is one.
@available(iOS 18.0, *)
struct OpenRoomControl: ControlWidget {
    static let kind = "app.sapoche.control.room"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenRoomIntent(code: WidgetStorage.shared()?.read()?.roomCode)) {
                Label(Language.t("Mở phòng", "Open the room"), systemImage: "person.2.fill")
            }
        }
        .displayName(LocalizedStringResource(stringLiteral: Language.t("Mở phòng", "Open the room")))
        .description(LocalizedStringResource(stringLiteral: Language.t("Mở Sapoche ở phòng của bạn.", "Opens Sapoche on your room.")))
    }
}
