import SwiftUI
import UIKit
import WidgetKit

/// What a widget is drawn from: the song and room as the app last wrote them, and its cover.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let cover: UIImage?
    /// The colour of the cover as a glow; the brand's pink without a cover.
    let accent: Color
    /// The shared folder was found. Without it the app and the widgets cannot hear of each other.
    let linked: Bool

    init(date: Date, snapshot: WidgetSnapshot, cover: UIImage?, linked: Bool = true) {
        self.date = date
        self.snapshot = snapshot
        self.cover = cover
        self.accent = cover.flatMap(Palette.accent) ?? .sapoche
        self.linked = linked
    }

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

    /// Words in the language of the app, as it wrote it; the phone's own before the app ever has.
    func t(_ vi: String, _ en: String) -> String {
        (snapshot.language.isEmpty ? Language.system : snapshot.language) == "vi" ? vi : en
    }

    static func load() -> SnapshotEntry {
        guard let storage = WidgetStorage.shared() else {
            return SnapshotEntry(date: Date(), snapshot: WidgetSnapshot(), cover: nil, linked: false)
        }
        return SnapshotEntry(
            date: Date(), snapshot: storage.read() ?? WidgetSnapshot(), cover: storage.cover().flatMap(UIImage.init(data:))
        )
    }

    static let sample = SnapshotEntry(
        date: Date(),
        snapshot: WidgetSnapshot(
            title: "MAKING MY WAY", artist: "Sơn Tùng M-TP", playing: true, room: "Weekend · 4", roomCode: "ABC123",
            crew: ["Lan", "Minh", "Hà"],
            next: [.init(title: "Cheri Cheri Lady", artist: "Maléna", by: "Lan"), .init(title: "STAY", artist: "The Kid LAROI", by: "Minh"),
                   .init(title: "Có Chắc Yêu Là Đây", artist: "Sơn Tùng M-TP", by: "Hà")],
            startedAt: Date().addingTimeInterval(-60), endsAt: Date().addingTimeInterval(120),
            friends: .init(code: "ABC123", room: "Weekend", who: ["Lan", "Minh"], song: "STAY"),
            playlist: .init(id: 1, name: "Gym")
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

/// The language of the phone, for what is said before the app has said its own, and for the names in the widget gallery.
enum Language {
    static var system: String { Locale.current.language.languageCode?.identifier == "vi" ? "vi" : "en" }

    static func t(_ vi: String, _ en: String) -> String { system == "vi" ? vi : en }
}

/// Sapoche's pink, for the buttons and the room line.
extension Color {
    static let sapoche = Color(red: 0.847, green: 0.106, blue: 0.376)
    static let plum = Color(red: 0.165, green: 0.063, blue: 0.125)
    /// Words on the dark picture behind every widget.
    static let softWhite = Color.white.opacity(0.78)
}

/// Colours taken from a cover.
enum Palette {
    /// The cover's average colour made vivid, and not so dark that it vanishes: the glow in the corner of a widget.
    static func accent(_ image: UIImage) -> Color? {
        guard let cg = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(1, max(0.35, saturation * 1.25)), brightness: min(0.95, max(0.55, brightness)))
    }

    /// A colour for a person's initial, the same for the same name.
    static func face(_ name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return Color(hue: Double(sum) / 360, saturation: 0.55, brightness: 0.75)
    }
}

/// What every widget is painted on, the same as the Android ones: the colours of the cover, blurred and darkened so that
/// white words read, a deeper foot for the buttons and a glow of the cover's own colour in the top left corner. Without a
/// cover, the brand's pink going to plum.
struct WidgetBackdrop: View {
    let cover: UIImage?
    let accent: Color

    var body: some View {
        ZStack {
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill().blur(radius: 30).scaleEffect(1.25)
                Color(red: 0.03, green: 0.016, blue: 0.04).opacity(0.47)
            } else {
                LinearGradient(colors: [.sapoche, .plum], startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.black.opacity(0.24)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: UnitPoint(x: 0.5, y: 0.35), endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.43), .clear], center: UnitPoint(x: 0.12, y: 0.05), startRadius: 0, endRadius: 240)
        }
        .clipped()
    }
}

/// A cover filling its frame; it keeps its colours when the system tints the widget (iOS 18 and later).
@ViewBuilder func coverImage(_ image: UIImage) -> some View {
    if #available(iOS 18.0, *) {
        Image(uiImage: image).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
    } else {
        Image(uiImage: image).resizable().scaledToFill()
    }
}

/// People as overlapping circles with their initials.
struct Faces: View {
    let names: [String]
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { _, name in
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Palette.face(name)))
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            }
        }
    }
}

/// A round button of a widget: the white one that plays, and the ones of frosted white beside it.
struct RoundGlyph: View {
    let symbol: String
    var size: CGFloat = 38
    var filled = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(filled ? Color.black.opacity(0.85) : Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(filled ? Color.white : Color.white.opacity(0.18)))
    }
}
