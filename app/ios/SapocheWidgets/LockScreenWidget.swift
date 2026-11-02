import SwiftUI
import WidgetKit

/// "Now playing" under the clock of the lock screen: a ring with the song's time, two lines, or one line.
struct LockScreenWidget: Widget {
    static let kind = "app.sapoche.widget.lockscreen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            LockScreenView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName(Language.t("Đang phát", "Now playing"))
        .description(Language.t("Bài đang phát, ngay trên màn khoá.", "The song that plays, on the lock screen."))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockScreenView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var shown: WidgetSnapshot { entry.snapshot }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            default: inline
            }
        }
        .widgetURL(shown.roomCode.flatMap { URL(string: "sapoche://join/\($0)") })
    }

    private var symbol: String { shown.playing ? "pause.fill" : "play.fill" }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let span = entry.span {
                ProgressView(timerInterval: span, countsDown: false) {
                    Image(systemName: symbol)
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
            } else if let fraction = entry.fraction {
                Gauge(value: fraction) { Image(systemName: symbol) }
                    .gaugeStyle(.accessoryCircularCapacity)
            } else {
                Image(systemName: "music.note")
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(shown.isIdle ? "Sapoche" : shown.title).font(.headline).lineLimit(1).widgetAccentable()
            Text(shown.isIdle ? entry.t("Chưa phát gì", "Nothing playing") : shown.artist).font(.caption).lineLimit(1)
            if let room = shown.room {
                Text(room).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Text(shown.isIdle ? "Sapoche" : "♪ \(shown.title) – \(shown.artist)")
    }
}
