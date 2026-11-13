import Foundation

/// What the Live Activity of a run of downloads shows: which song of how many, and how it ended. The app starts and updates
/// the activity; the widgets' target draws it.
///
/// This file is also compiled into the widgets' own target, so it uses nothing but Foundation.
public struct DownloadActivityContent: Codable, Hashable, Sendable {
    /// The song being fetched; empty when none is.
    public var title: String
    public var done: Int
    public var total: Int
    public var failed: Int
    /// The run is over.
    public var finished: Bool
    /// The app lost the time the system gives it in the background: the run goes on when it is opened again.
    public var paused: Bool
    /// The language of the app (`vi` or `en`), which the activity speaks.
    public var language: String

    public init(title: String, done: Int, total: Int, failed: Int, finished: Bool = false, paused: Bool = false, language: String) {
        self.title = title
        self.done = done
        self.total = total
        self.failed = failed
        self.finished = finished
        self.paused = paused
        self.language = language
    }

    /// The place of the song being fetched among the run's, from 1.
    public var position: Int { min(max(done + failed + 1, 1), max(total, 1)) }

    /// How far the run has come, 0 to 1.
    public var fraction: Double { total > 0 ? Double(done + failed) / Double(total) : 0 }

    private var vi: Bool { language == "vi" }

    /// The first line. [stale]: the system says nothing new came for a while, which is as good as being paused.
    public func headline(stale: Bool = false) -> String {
        if finished {
            if failed == 0 { return vi ? "Đã tải xong \(done) bài" : (done == 1 ? "Downloaded 1 song" : "Downloaded \(done) songs") }
            return vi ? "Đã tải \(done) bài, \(failed) bài không tải được" : "Downloaded \(done), \(failed) could not be downloaded"
        }
        if paused || stale { return vi ? "Tạm dừng" : "Paused" }
        return vi ? "Đang tải \(position)/\(total)" : "Downloading \(position) of \(total)"
    }

    /// The second line: the song being fetched, or what to do about a pause.
    public func subline(stale: Bool = false) -> String {
        if finished { return "" }
        if paused || stale { return vi ? "Mở Sapoche để tải tiếp" : "Open Sapoche to continue" }
        return title
    }
}
