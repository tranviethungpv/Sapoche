import ActivityKit
import SwiftUI
import WidgetKit

/// The room on the lock screen and in the Dynamic Island while this device is in one.
struct RoomLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RoomActivityAttributes.self) { context in
            LockScreenRoom(context: context)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "sapoche://join/\(context.attributes.roomCode)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note.list").foregroundStyle(Color.sapoche)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label("\(context.state.members)", systemImage: "person.2.fill").font(.caption)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(context.state.title.isEmpty ? context.attributes.roomName : context.state.title)
                            .font(.headline).lineLimit(1)
                        Text(context.state.title.isEmpty ? "Nothing playing" : context.state.artist)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let started = context.state.startedAt, let ends = context.state.endsAt, ends > started {
                        ProgressView(timerInterval: started...ends, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                            .tint(Color.sapoche)
                    } else {
                        Text(context.attributes.roomName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill").foregroundStyle(Color.sapoche)
            } compactTrailing: {
                Text("\(context.state.members)").font(.caption)
            } minimal: {
                Image(systemName: "music.note").foregroundStyle(Color.sapoche)
            }
            .widgetURL(URL(string: "sapoche://join/\(context.attributes.roomCode)"))
        }
    }
}

struct LockScreenRoom: View {
    let context: ActivityViewContext<RoomActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(context.attributes.roomName, systemImage: "person.2.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.sapoche)
                Spacer()
                Text("\(context.state.members) listening").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(context.state.title.isEmpty ? "Nothing playing" : context.state.title)
                .font(.system(size: 16, weight: .bold)).lineLimit(1)
            if !context.state.title.isEmpty {
                Text(context.state.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let started = context.state.startedAt, let ends = context.state.endsAt, ends > started {
                ProgressView(timerInterval: started...ends, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(Color.sapoche)
            }
        }
        .padding(14)
    }
}
