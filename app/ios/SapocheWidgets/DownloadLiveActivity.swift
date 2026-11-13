import ActivityKit
import SwiftUI
import WidgetKit

/// A run of downloads on the lock screen and in the Dynamic Island: which song of how many, and how it ended. The app
/// starts it and tells it each song (DownloadActivityContent); nothing comes from a server, so when the app is not allowed
/// to run it stops changing, and the system marks it stale, which is drawn as paused.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenDownload(content: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let content = context.state
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: icon(content, stale: stale)).foregroundStyle(Color.sapoche)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !content.finished { Text("\(content.position)/\(content.total)").font(.caption.monospacedDigit()) }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(content.headline(stale: stale)).font(.headline).lineLimit(1)
                        let line = content.subline(stale: stale)
                        if !line.isEmpty { Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !content.finished { ProgressView(value: content.fraction).tint(Color.sapoche) }
                }
            } compactLeading: {
                Image(systemName: icon(content, stale: stale)).foregroundStyle(Color.sapoche)
            } compactTrailing: {
                if !content.finished { Text("\(content.position)/\(content.total)").font(.caption.monospacedDigit()) }
            } minimal: {
                Image(systemName: icon(content, stale: stale)).foregroundStyle(Color.sapoche)
            }
        }
    }

    private func icon(_ content: DownloadActivityContent, stale: Bool) -> String {
        if content.finished { return content.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill" }
        return content.paused || stale ? "pause.circle.fill" : "arrow.down.circle.fill"
    }
}

struct LockScreenDownload: View {
    let content: DownloadActivityContent
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Sapoche", systemImage: content.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.sapoche)
                Spacer()
                if !content.finished {
                    Text("\(content.position)/\(content.total)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(content.headline(stale: stale)).font(.system(size: 16, weight: .bold)).lineLimit(1)
            let line = content.subline(stale: stale)
            if !line.isEmpty { Text(line).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
            if !content.finished { ProgressView(value: content.fraction).tint(Color.sapoche) }
        }
        .padding(14)
    }
}
