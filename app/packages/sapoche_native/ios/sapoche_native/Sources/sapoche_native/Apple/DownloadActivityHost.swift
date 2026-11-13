import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Carries out the steps of [DownloadActivityPlan] on the system's Live Activity. A step is waited for before the next
/// is given: the system refuses updates that come in a heap, and an old state must never land after a newer one.
@MainActor
final class DownloadActivityHost {
    private var queue: Task<Void, Never>?

    func run(_ step: DownloadActivityPlan.Step) {
        #if canImport(ActivityKit)
        // The drawing of it lives in the widgets' extension, which is for iOS 17 and later: before that there is nothing to show it
        guard #available(iOS 17.0, *) else { return }
        let before = queue
        queue = Task {
            await before?.value
            await Self.apply(step)
        }
        #endif
    }

    #if canImport(ActivityKit)
    /// Without word from the app for this long the system calls the activity stale, which it draws as paused: the net under
    /// the pause the app puts there itself when the system takes its time back, which may come too late.
    private static let staleAfter: TimeInterval = 120
    /// A run that is over stays on the lock screen for this long.
    private static let lingerFor: TimeInterval = 300

    @available(iOS 17.0, *)
    private static func apply(_ step: DownloadActivityPlan.Step) async {
        let running = Activity<DownloadActivityAttributes>.activities
        switch step {
        case .none:
            return
        case .start(let content):
            // One from an earlier run is not to stay beside the new one
            for old in running { await old.end(nil, dismissalPolicy: .immediate) }
            // Whoever turned Live Activities off in Settings, or an app that is not in front, gets none: the app tells the same itself
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            _ = try? Activity.request(
                attributes: DownloadActivityAttributes(),
                content: ActivityContent(state: content, staleDate: Date().addingTimeInterval(staleAfter)),
                pushType: nil
            )
        case .update(let content):
            for activity in running {
                await activity.update(ActivityContent(state: content, staleDate: content.paused ? nil : Date().addingTimeInterval(staleAfter)))
            }
        case .finish(let content):
            for activity in running {
                await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(lingerFor)))
            }
        case .close:
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
    #endif
}
