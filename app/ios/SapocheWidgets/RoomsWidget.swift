import SwiftUI
import WidgetKit

/// Who listens: in a room, the room and its song; outside one, the friends in the rooms this device has been in, with a way
/// to join. What it knows of the friends is what the app last asked the server, which it does when it runs.
struct RoomsWidget: Widget {
    static let kind = "app.sapoche.widget.rooms"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            RoomsView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackdrop(cover: entry.cover, accent: entry.accent) }
        }
        .configurationDisplayName(Language.t("Phòng và bạn bè", "Room and friends"))
        .description(Language.t("Ai đang nghe, và một chạm để vào nghe cùng.", "Who is listening, and a touch to join."))
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct RoomsView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    /// What is said, from where this device is: in a room, with friends in one, or with neither.
    private struct Say {
        var title: String
        var sub: String
        var names: [String]
        var button: String
        var link: String?
    }

    private var say: Say {
        let shown = entry.snapshot
        if let code = shown.roomCode {
            return Say(
                title: shown.room ?? code, sub: shown.isIdle ? entry.t("Chưa phát gì", "Nothing playing") : shown.title,
                names: shown.crew, button: entry.t("Mở", "Open"), link: "sapoche://join/\(code)"
            )
        }
        if let friends = shown.friends {
            let listening = !friends.who.isEmpty
            let who = friends.who.prefix(2).joined(separator: ", ")
            return Say(
                title: listening ? entry.t("\(who) đang nghe", "\(who) listening") : entry.t("Chưa ai nghe", "Nobody is listening"),
                sub: listening ? [friends.room, friends.song].compactMap { $0 }.joined(separator: " · ")
                    : entry.t("Phòng gần nhất: \(friends.room)", "Last room: \(friends.room)"),
                names: listening ? friends.who : [friends.room],
                button: listening ? entry.t("Vào nghe", "Join") : entry.t("Mở phòng", "Open"), link: "sapoche://join/\(friends.code)"
            )
        }
        return Say(
            title: entry.linked ? entry.t("Chưa có phòng", "No rooms yet") : entry.t("Chưa nối với app", "Not linked to the app"),
            sub: entry.t("Tạo hoặc vào một phòng", "Start or join a room"), names: [], button: entry.t("Mở", "Open"), link: nil
        )
    }

    var body: some View {
        let say = self.say
        Group {
            if family == .systemSmall { small(say) } else { medium(say) }
        }
        .foregroundStyle(.white)
        .widgetURL(say.link.flatMap { URL(string: $0) })
    }

    private func faces(_ say: Say, size: CGFloat) -> some View {
        Group {
            if say.names.isEmpty {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: size * 0.5))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(0.18)))
            } else {
                Faces(names: say.names, size: size)
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white))
    }

    private func small(_ say: Say) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            faces(say, size: 30)
            Spacer(minLength: 4)
            Text(say.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
            Text(say.sub).font(.system(size: 12)).foregroundStyle(Color.softWhite).lineLimit(1)
            pill(say.button).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
    }

    private func medium(_ say: Say) -> some View {
        HStack(spacing: 12) {
            faces(say, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(say.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text(say.sub).font(.system(size: 13)).foregroundStyle(Color.softWhite).lineLimit(2)
            }
            Spacer(minLength: 4)
            pill(say.button)
        }
        .padding(16)
    }
}
