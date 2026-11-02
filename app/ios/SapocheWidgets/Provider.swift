import SwiftUI
import UIKit
import WidgetKit

/// What a widget is drawn from: the song and room as the app last wrote them, and its cover.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let cover: UIImage?

    /// How far into the song it was when this was written, 0...1; nil when it has no length.
    var fraction: Double? {
        guard let started = snapshot.startedAt, let ends = snapshot.endsAt, ends > started else { return nil }
        return min(1, max(0, snapshot.updatedAt.timeIntervalSince(started) / ends.timeIntervalSince(started)))
    }

    /// The song to count along with by itself while it plays.
    var span: ClosedRange<Date>? {
        guard snapshot.playing, let started = snapshot.startedAt, let ends = snapshot.endsAt, ends > started else { return nil }
        return started...ends
    }

    static func load() -> SnapshotEntry {
        let storage = WidgetStorage.shared()
        let snapshot = storage?.read() ?? WidgetSnapshot()
        return SnapshotEntry(date: Date(), snapshot: snapshot, cover: storage?.cover().flatMap(UIImage.init(data:)))
    }

    static let sample = SnapshotEntry(
        date: Date(),
        snapshot: WidgetSnapshot(
            title: "MAKING MY WAY", artist: "Sơn Tùng M-TP", playing: true, room: "Weekend · 4", roomCode: "ABC123",
            crew: ["Lan", "Minh", "Hà"],
            next: [.init(title: "Cheri Cheri Lady", artist: "Maléna", by: "Lan"), .init(title: "STAY", artist: "The Kid LAROI", by: "Minh"),
                   .init(title: "Có Chắc Yêu Là Đây", artist: "Sơn Tùng M-TP", by: "Hà")],
            startedAt: Date().addingTimeInterval(-60), endsAt: Date().addingTimeInterval(120)
        ),
        cover: nil
    )
}

/// The app asks for the widgets to be drawn again whenever what they show changes, so a timeline is one entry that
/// lasts: the song's own time is counted by the system.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? .sample : .load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [.load()], policy: .never))
    }
}

/// Sapoche's pink, for the buttons and the room line.
extension Color {
    static let sapoche = Color(red: 0.847, green: 0.106, blue: 0.376)
}

/// A cover filling its frame; it keeps its colours when the system tints the widget (iOS 18 and later).
@ViewBuilder func coverImage(_ image: UIImage) -> some View {
    if #available(iOS 18.0, *) {
        Image(uiImage: image).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
    } else {
        Image(uiImage: image).resizable().scaledToFill()
    }
}
