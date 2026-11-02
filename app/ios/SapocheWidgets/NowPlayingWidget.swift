import AppIntents
import SwiftUI
import WidgetKit

/// "Now playing" on the home screen, in three sizes. A touch opens the app; the buttons play, pause and skip without it.
struct NowPlayingWidget: Widget {
    static let kind = "app.sapoche.widget.nowplaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            NowPlayingView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackdrop(cover: entry.cover, accent: entry.accent) }
        }
        .configurationDisplayName(Language.t("Đang phát", "Now playing"))
        .description(Language.t("Bài đang phát, có nút phát, dừng và chuyển bài.", "What plays now, with play, pause and skip."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct NowPlayingView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var shown: WidgetSnapshot { entry.snapshot }
    private var title: String { shown.isIdle ? "Sapoche" : shown.title }
    private var subtitle: String {
        if !entry.linked { return entry.t("Chưa nối với app", "Not linked to the app") }
        return shown.isIdle ? entry.t("Chưa phát gì", "Nothing playing") : shown.artist
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            default: large
            }
        }
        .foregroundStyle(.white)
        .widgetURL(shown.roomCode.flatMap { URL(string: "sapoche://join/\($0)") })
    }

    // ------------------------------------------------------------------ pieces

    private func cover(_ side: CGFloat, radius: CGFloat = 14) -> some View {
        Group {
            if let image = entry.cover {
                coverImage(image)
            } else {
                ZStack {
                    Color.white.opacity(0.14)
                    Image(systemName: "music.note").font(.system(size: side * 0.4)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var playButton: some View {
        Button(intent: PlayPauseIntent()) {
            RoundGlyph(symbol: shown.playing ? "pause.fill" : "play.fill", filled: true)
        }
        .buttonStyle(.plain)
    }

    private func skip(_ intent: some AppIntent, _ symbol: String) -> some View {
        Button(intent: intent) { RoundGlyph(symbol: symbol) }
            .buttonStyle(.plain)
            .opacity(shown.canSteer ? 1 : 0.3)
            .disabled(!shown.canSteer)
    }

    private var progress: some View {
        Group {
            if let span = entry.span {
                ProgressView(timerInterval: span, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else if let fraction = entry.fraction {
                ProgressView(value: fraction)
            }
        }
        .tint(Color.white)
        .progressViewStyle(.linear)
    }

    private var roomLine: some View {
        Group {
            if let room = shown.room {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill").font(.system(size: 10))
                    Text(room).lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .widgetAccentable()
            }
        }
    }

    // ------------------------------------------------------------------ sizes

    private var small: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = entry.cover {
                coverImage(image)
            } else {
                Color.clear
            }
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: UnitPoint(x: 0.5, y: 0.38), endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).lineLimit(1).foregroundStyle(Color.softWhite)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack {
                HStack {
                    Spacer()
                    playButton
                }
                Spacer()
            }
            .padding(10)
        }
        .clipped()
    }

    private var medium: some View {
        HStack(spacing: 14) {
            cover(104)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.softWhite).lineLimit(1)
                roomLine
                Spacer(minLength: 2)
                progress
                HStack {
                    skip(PreviousIntent(), "backward.fill")
                    Spacer()
                    playButton
                    Spacer()
                    skip(NextIntent(), "forward.fill")
                }
            }
        }
        .padding(14)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                cover(96)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.softWhite).lineLimit(1)
                    roomLine
                    Spacer(minLength: 2)
                    HStack {
                        skip(PreviousIntent(), "backward.fill")
                        playButton
                        skip(NextIntent(), "forward.fill")
                    }
                }
            }
            progress
            if !shown.next.isEmpty {
                Divider().overlay(Color.white.opacity(0.25))
                Text(entry.t("TIẾP THEO", "UP NEXT")).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.softWhite)
                ForEach(Array(shown.next.enumerated()), id: \.offset) { _, row in
                    queueRow(row)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    /// A song of the queue; a touch jumps to it when this device may move the player.
    @ViewBuilder private func queueRow(_ row: WidgetSnapshot.Row) -> some View {
        let content = HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(row.artist).font(.system(size: 12)).foregroundStyle(Color.softWhite).lineLimit(1)
            }
            Spacer()
            if let by = row.by {
                Text(String(by.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.face(by)))
                    .foregroundStyle(.white)
            }
        }
        if let id = row.id, shown.canSteer {
            Button(intent: JumpIntent(itemId: id)) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}
