import Foundation

/// Decides what the Live Activity of a run of downloads does as the run moves: opened when a run starts, changed when a
/// song starts or ends, left on show for a while when the run is over. Kept apart from ActivityKit so that it can be tested
/// without a phone.
struct DownloadActivityPlan {
    enum Step: Equatable {
        case none
        /// Open it.
        case start(DownloadActivityContent)
        case update(DownloadActivityContent)
        /// The run is over: show how it went, then let it go by itself after a while.
        case finish(DownloadActivityContent)
        /// The run was cut short: take it away at once.
        case close
    }

    /// What the open activity shows; nil when none is open.
    private var shown: DownloadActivityContent?

    /// How the run stands. [canOpen]: the system opens an activity only while the app is in front. [quiet]: a run the
    /// phone makes by itself (liked songs) never opens one.
    mutating func step(_ batch: Downloader.Batch, title: String, language: String, canOpen: Bool, quiet: Bool) -> Step {
        if batch.active != nil {
            let content = DownloadActivityContent(title: title, done: batch.done, total: batch.total, failed: batch.failed, language: language)
            guard shown != nil else {
                guard canOpen, !quiet else { return .none }
                shown = content
                return .start(content)
            }
            if shown == content { return .none }
            shown = content
            return .update(content)
        }
        if batch.total > 0 {
            guard shown != nil else { return .none }
            shown = nil
            return .finish(DownloadActivityContent(title: "", done: batch.done, total: batch.total, failed: batch.failed, finished: true, language: language))
        }
        guard shown != nil else { return .none }
        shown = nil
        return .close
    }

    /// The time the system gives the app in the background is up: nothing more will come until it is opened again.
    mutating func timeUp() -> Step {
        guard var content = shown, !content.paused else { return .none }
        content.paused = true
        shown = content
        return .update(content)
    }
}
