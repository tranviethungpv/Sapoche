import AppIntents
import SwiftUI
import WidgetKit

/// Four tiles that play a list with one touch, without opening the app: liked songs, a mix for you, downloads and the
/// playlist touched last.
struct QuickWidget: Widget {
    static let kind = "app.sapoche.widget.quick"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            QuickView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackdrop(cover: entry.cover, accent: entry.accent) }
        }
        .configurationDisplayName(Language.t("Nghe nhanh", "Quick play"))
        .description(Language.t("Bài thích, Mix gợi ý, Tải về và playlist gần nhất: một chạm là phát.", "Liked, Mix, Downloads and your latest playlist: one touch plays."))
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct QuickView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private struct Tile: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let intent: QuickPlayIntent
    }

    /// In a room the songs are the room's to pick, so the tiles wait until this device is out of it.
    private var inRoom: Bool { entry.snapshot.roomCode != nil }

    private var tiles: [Tile?] {
        [
            Tile(id: "liked", label: entry.t("Bài thích", "Liked"), symbol: "heart.fill", intent: QuickPlayIntent(list: "liked")),
            Tile(id: "mix", label: entry.t("Mix gợi ý", "Mix"), symbol: "wand.and.stars", intent: QuickPlayIntent(list: "mix")),
            Tile(id: "downloads", label: entry.t("Tải về", "Downloads"), symbol: "arrow.down.circle.fill", intent: QuickPlayIntent(list: "downloads")),
            entry.snapshot.playlist.map {
                Tile(id: "playlist", label: $0.name, symbol: "music.note.list", intent: QuickPlayIntent(list: "playlist", playlist: Int($0.id)))
            },
        ]
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                VStack(spacing: 8) {
                    HStack(spacing: 8) { tile(tiles[0]); tile(tiles[1]) }
                    HStack(spacing: 8) { tile(tiles[2]); tile(tiles[3]) }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { tile(tiles[$0]) }
                }
            }
        }
        .padding(family == .systemSmall ? 12 : 14)
        .foregroundStyle(.white)
        .opacity(inRoom ? 0.45 : 1)
    }

    @ViewBuilder private func tile(_ tile: Tile?) -> some View {
        if let tile {
            Button(intent: tile.intent) {
                VStack(spacing: 5) {
                    Image(systemName: tile.symbol).font(.system(size: 22, weight: .semibold))
                    Text(tile.label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .disabled(inRoom)
        } else {
            // With no playlist yet the fourth tile has nothing to play
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
