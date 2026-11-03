import Foundation

/// Where a song that plays came from, kept beside every listen and skip so the suggestions can be judged by their source.
enum ListenSource {
    /// Picked on purpose: a search, the library, a playlist. Also what an old row without a source is taken for.
    static let chosen = "chosen"
    /// Added by autoplay or by a radio, in the personal queue or in a room.
    static let auto = "auto"
    /// Started from a shelf of the home page (Quick picks, a mix, Discover...).
    static let shelf = "shelf"
    /// In a room, a song another member put on the queue.
    static let roomOther = "room_other"

    /// What a song somebody else picked says about this person's taste, next to one they picked themselves (1).
    static let otherWeight = 0.5

    static func weight(_ source: String?) -> Double { source == roomOther ? otherWeight : 1 }
}

/// Remembers which songs of the queue were put there by autoplay or from a shelf, so a listen can say where it came
/// from. A song put on the queue by hand is forgotten here, because `chosen` is what is left. Only the latest [keep]
/// songs are kept.
final class ListenSources: @unchecked Sendable {
    private let keep: Int
    private let lock = NSLock()
    private var marked: [String: String] = [:]
    private var order: [String] = []

    init(keep: Int = 400) { self.keep = keep }

    func mark(_ ids: [String], source: String) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            if marked.removeValue(forKey: id) != nil { order.removeAll { $0 == id } }
            if source != ListenSource.chosen {
                marked[id] = source
                order.append(id)
            }
        }
        while order.count > keep { marked.removeValue(forKey: order.removeFirst()) }
    }

    /// The source of [videoId]. In a room, [item] is the queue item playing and [you] this device's public id: what
    /// autoplay put there and what others put there say so themselves.
    func of(_ videoId: String, item: QueueItem? = nil, you: String? = nil) -> String {
        if let item {
            if item.auto { return ListenSource.auto }
            if let you, item.addedBy != you { return ListenSource.roomOther }
        }
        lock.lock()
        defer { lock.unlock() }
        return marked[videoId] ?? ListenSource.chosen
    }
}
