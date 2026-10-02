import Foundation

/// What is kept of the personal queue between runs.
struct SavedQueue: Equatable, Codable {
    var queue: [QueueItem] = []
    var index = 0
    var repeatMode = "off"
    /// Where the current item resumes.
    var positionMs: Int64 = 0
    var finished = false

    enum CodingKeys: String, CodingKey {
        case queue, index, positionMs, finished
        case repeatMode = "repeat"
    }

    init(queue: [QueueItem] = [], index: Int = 0, repeatMode: String = "off", positionMs: Int64 = 0, finished: Bool = false) {
        self.queue = queue
        self.index = index
        self.repeatMode = repeatMode
        self.positionMs = positionMs
        self.finished = finished
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        queue = try values.decodeIfPresent([QueueItem].self, forKey: .queue) ?? []
        index = try values.decodeIfPresent(Int.self, forKey: .index) ?? 0
        repeatMode = try values.decodeIfPresent(String.self, forKey: .repeatMode) ?? "off"
        positionMs = try values.decodeIfPresent(Int64.self, forKey: .positionMs) ?? 0
        finished = try values.decodeIfPresent(Bool.self, forKey: .finished) ?? false
    }
}

/// [SavedQueue] as one JSON file. A write goes to a temporary file first, so a crash never leaves half a queue.
struct QueueFile {
    let url: URL

    func read() -> SavedQueue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedQueue.self, from: data)
    }

    func write(_ saved: SavedQueue) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// A random number generator that a test can replace with one that always does the same.
struct AnyRandom: RandomNumberGenerator {
    private var source: () -> UInt64

    init(_ source: @escaping () -> UInt64) {
        self.source = source
    }

    init() {
        var system = SystemRandomNumberGenerator()
        self.init { system.next() }
    }

    mutating func next() -> UInt64 { source() }
}

/// The queue a person listens to outside a room: an ordinary music player's queue that lives on this device and
/// survives restarts. It drives the same [PlayerPort] as [GroupSession] and never talks to the server. Only one of
/// the two owns the player at a time; [attach] and [detach] hand it over. Runs on the main thread.
@MainActor
final class LocalSession {
    struct Snapshot: Equatable {
        var queue: [QueueItem] = []
        var index = 0
        /// off, all or one, like the room's repeat.
        var repeatMode = "off"
        /// The queue ran out: nothing is playing, and play starts it again from the top.
        var finished = false

        var current: QueueItem? { queue.indices.contains(index) ? queue[index] : nil }
    }

    let snapshot: StateFlow<Snapshot>

    private let scope: Scope
    private let player: PlayerPort
    /// Called whenever what should be remembered changed.
    private let persist: (SavedQueue) -> Void
    /// Something the person should be told, e.g. a song that would not load.
    private let problem: (String) -> Void
    private let log: (String) -> Void
    /// The queue ran out of songs after the item given (it played through, or next was pressed on the last one).
    private let onQueueEnd: (QueueItem) -> Void
    private let newId: () -> String
    private var random: AnyRandom

    /// Queue item loaded in the player; nil after a restart until something is played.
    private var loadedId: String?

    /// Where the current item resumes once it is loaded.
    private var pendingPositionMs: Int64

    /// Item handed to the player as the gapless successor of the loaded one.
    private var preloaded: QueueItem?
    private var job: Job?

    /// Reloads used on the current item; stops endless retry loops on a broken stream.
    private var recoveries = 0

    /// Whether the item being loaded starts playing once it is ready; play and pause during a load only flip this.
    private var playOnLoad = false

    init(scope: Scope, player: PlayerPort, saved: SavedQueue?, persist: @escaping (SavedQueue) -> Void,
         problem: @escaping (String) -> Void = { _ in }, log: @escaping (String) -> Void = { _ in },
         onQueueEnd: @escaping (QueueItem) -> Void = { _ in }, newId: @escaping () -> String = { UUID().uuidString },
         random: AnyRandom = AnyRandom()) {
        self.scope = scope
        self.player = player
        self.persist = persist
        self.problem = problem
        self.log = log
        self.onQueueEnd = onQueueEnd
        self.newId = newId
        self.random = random
        snapshot = StateFlow(LocalSession.restore(saved))
        pendingPositionMs = saved?.finished == true ? 0 : saved?.positionMs ?? 0
    }

    /// Position to show for the current item while nothing is loaded (after a restart), else nil: the player knows
    /// better then.
    var restoredPositionMs: Int64? {
        loadedId == nil && snapshot.value.current != nil ? pendingPositionMs : nil
    }

    /// Take the player over: from now on its endings and errors are ours. Loads nothing.
    func attach() {
        // Only the end of a song this session loaded counts: a player that has nothing (a restart brought the
        // playback back from a media button) also reports "ended", and that must not finish the saved queue
        player.onEnded = { [weak self] in
            guard let self else { return }
            self.scope.launch { [weak self] in
                guard let self, self.loadedId != nil else { return }
                self.step(+1, auto: true)
            }
        }
        player.onAdvanced = { [weak self] in
            guard let self else { return }
            self.scope.launch { [weak self] in self?.onAdvanced() }
        }
        player.onError = { [weak self] error in
            guard let self else { return }
            self.scope.launch { [weak self] in self?.onPlayerError(error) }
        }
    }

    /// A room takes the player: silence it, but remember where this queue stood so it can be picked up again.
    func detach() {
        job?.cancel()
        if loadedId != nil { pendingPositionMs = player.positionMs() }
        loadedId = nil
        preloaded = nil
        player.stop()
        save()
    }

    // ------------------------------------------------------------------ transport

    func play() {
        let s = snapshot.value
        if loadedId == nil && job?.isActive == true {
            // Asked twice (a button and the lock screen both do): the item is on its way, do not start over
            playOnLoad = true
        } else if loadedId != nil {
            player.play()
        } else if s.queue.isEmpty {
            return
        } else if s.finished {
            // After the last song, play means "again": from the top of the list
            load(s.queue[0], 0, play: true)
        } else {
            load(s.queue[s.index], pendingPositionMs, play: true)
        }
    }

    func pause() {
        playOnLoad = false
        player.pause()
        save()
    }

    func seek(_ positionMs: Int64) {
        let target = max(positionMs, 0)
        if loadedId == nil {
            pendingPositionMs = target
            return
        }
        scope.launch { [weak self] in try await self?.player.seekTo(target) }
    }

    func next() { step(+1, auto: false) }

    /// Restart this song, or go to the one before it when it has only just begun.
    func prev() {
        if loadedId != nil && player.positionMs() > Self.prevRestartsAfterMs { seek(0) } else { step(-1, auto: false) }
    }

    func jump(_ id: String) {
        if let item = snapshot.value.queue.first(where: { $0.id == id }) { load(item, 0, play: true) }
    }

    // ------------------------------------------------------------------ queue

    /// Adds songs at the end, or right after the current one with [next]. With nothing to play, the first one starts.
    /// A song that is waiting in the queue already is left out.
    func add(_ tracks: [TrackRef], next: Bool) {
        let s = snapshot.value
        let startNow = s.queue.isEmpty || s.finished
        let fresh = Queues.fresh(tracks, queue: s.queue, index: s.finished ? s.queue.count : s.index)
        let room = Self.maxQueue - s.queue.count
        if !fresh.isEmpty && room <= 0 { return problem("The queue is full") }
        let items = fresh.prefix(max(room, 0)).map {
            QueueItem(id: newId(), videoId: $0.videoId, title: $0.title, artist: $0.artist, thumb: $0.thumb, durMs: $0.durMs, addedBy: "")
        }
        guard let first = items.first else { return }

        let at = next && !startNow ? s.index + 1 : s.queue.count
        var queue = s.queue
        queue.insert(contentsOf: items, at: at)
        snapshot.update { $0.queue = queue }
        if startNow { load(first, 0, play: true) } else { preload() }
        save()
    }

    func remove(_ id: String) {
        let s = snapshot.value
        guard let at = s.queue.firstIndex(where: { $0.id == id }) else { return }
        var queue = s.queue
        queue.remove(at: at)
        if at < s.index {
            snapshot.update { $0.queue = queue; $0.index = s.index - 1 }
        } else if at > s.index {
            snapshot.update { $0.queue = queue }
        } else if queue.isEmpty {
            stopPlayer()
            let repeatMode = snapshot.value.repeatMode
            snapshot.set(Snapshot(repeatMode: repeatMode))
        } else if at < queue.count {
            // The next song takes the place of the one removed, and plays if that one was playing
            let play = loadedId == id && player.isPlaying()
            snapshot.update { $0.queue = queue }
            if loadedId == id { load(queue[at], 0, play: play) } else { pendingPositionMs = 0 }
        } else {
            stopPlayer()
            snapshot.update { $0.queue = queue; $0.index = queue.count - 1; $0.finished = true }
        }
        preload()
        save()
    }

    /// Puts [track], another release of the same song (its video for its audio, or back), in place of the item [id].
    /// If that item is loaded, the new release takes over from the same moment, playing if it was playing.
    func swap(_ id: String, _ track: TrackRef) {
        let s = snapshot.value
        guard let at = s.queue.firstIndex(where: { $0.id == id }), s.queue[at].videoId != track.videoId else { return }
        var item = s.queue[at]
        item.videoId = track.videoId
        item.title = track.title
        item.artist = track.artist
        item.thumb = track.thumb
        item.durMs = track.durMs
        snapshot.update { $0.queue[at] = item }
        if loadedId == id {
            let end = item.durMs > 0 ? item.durMs : Int64.max
            // A player that is buffering does not report playing, but the person did not pause it
            load(item, min(player.positionMs(), end), play: player.isPlaying() || playOnLoad)
        } else {
            preload()
        }
        save()
    }

    func move(_ id: String, toIndex: Int) {
        let s = snapshot.value
        guard let from = s.queue.firstIndex(where: { $0.id == id }) else { return }
        let currentId = s.current?.id
        var queue = s.queue
        let moved = queue.remove(at: from)
        queue.insert(moved, at: min(max(toIndex, 0), queue.count))
        let index = currentId.flatMap { current in queue.firstIndex { $0.id == current } } ?? 0
        snapshot.update { $0.queue = queue; $0.index = index }
        preload()
        save()
    }

    func clear() {
        stopPlayer()
        let repeatMode = snapshot.value.repeatMode
        snapshot.set(Snapshot(repeatMode: repeatMode))
        save()
    }

    /// Mixes up what is still to come, so the song playing carries on. Once the queue has finished it mixes the whole
    /// list and plays from the top: the way to hear it again in a new order.
    func shuffle() {
        let s = snapshot.value
        if s.queue.count < 2 { return }
        var queue = s.queue
        if s.finished {
            queue.shuffle(using: &random)
            snapshot.update { $0.queue = queue }
            load(queue[0], 0, play: true)
        } else {
            let from = s.index + 1
            var tail = Array(queue[from...])
            tail.shuffle(using: &random)
            queue.replaceSubrange(from..., with: tail)
            snapshot.update { $0.queue = queue }
            preload()
        }
        save()
    }

    func setRepeat(_ mode: String) {
        if mode != "off" && mode != "all" && mode != "one" { return }
        if mode == snapshot.value.repeatMode { return }
        snapshot.update { $0.repeatMode = mode }
        preload()
        save()
    }

    /// Writes down the queue and where it stands; called on every change and when playback stops.
    func save() {
        let s = snapshot.value
        let position = loadedId != nil ? player.positionMs() : pendingPositionMs
        persist(SavedQueue(queue: s.queue, index: s.index, repeatMode: s.repeatMode, positionMs: position, finished: s.finished))
    }

    // ------------------------------------------------------------------ playing

    /// Moves [delta] items along the queue; at the ends it wraps when repeating all, and otherwise stops.
    private func step(_ delta: Int, auto: Bool) {
        let s = snapshot.value
        if s.queue.isEmpty { return }
        var target = s.finished && delta < 0 ? s.index : s.index + delta
        if auto && s.repeatMode == "one" { target = s.index }
        if target >= s.queue.count { target = s.repeatMode == "all" ? 0 : -1 }
        if target < 0 {
            if delta < 0 { target = 0 } else { return finish() }
        }
        load(s.queue[target], 0, play: true)
    }

    /// Ran out of songs: nothing is current until play starts the list again.
    private func finish() {
        let last = snapshot.value.queue.last
        stopPlayer()
        snapshot.update { $0.index = $0.queue.count - 1; $0.finished = true }
        save()
        if let last { onQueueEnd(last) }
    }

    private func stopPlayer() {
        job?.cancel()
        player.stop()
        loadedId = nil
        preloaded = nil
        pendingPositionMs = 0
    }

    private func load(_ item: QueueItem, _ positionMs: Int64, play: Bool) {
        // The tries are counted for the song, not its place: a new song where the last one was starts from none
        if item.id != loadedId { recoveries = 0 }
        job?.cancel()
        preloaded = nil
        loadedId = nil
        guard let at = snapshot.value.queue.firstIndex(where: { $0.id == item.id }) else { return }
        // The person sees the new song at once, not when it has loaded
        snapshot.update { $0.index = at; $0.finished = false }
        playOnLoad = play
        job = scope.launch { [weak self] in
            guard let self else { return }
            do {
                try await self.player.prepare(item, seekToMs: positionMs)
                self.loadedId = item.id
                self.pendingPositionMs = 0
                if self.playOnLoad { self.player.play() }
                self.preload()
                self.save()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.log("could not load '\(item.title)': \(error.localizedDescription)")
                self.pendingPositionMs = positionMs
                self.problem("Could not load: \(item.title)\n\(Self.cause(error))")
            }
        }
    }

    /// What went wrong, short enough for a message; the person can tell it to whoever fixes the app.
    private static func cause(_ error: Error) -> String {
        let ns = error as NSError
        return String("\(error.localizedDescription) (\(ns.domain) \(ns.code))".prefix(200))
    }

    /// Keeps the gapless successor equal to the song after the one loaded.
    private func preload() {
        let s = snapshot.value
        var wanted: QueueItem?
        if loadedId != nil, s.current?.id == loadedId, s.repeatMode != "one", s.queue.indices.contains(s.index + 1) {
            wanted = s.queue[s.index + 1]
        }
        if wanted == preloaded { return }
        preloaded = wanted
        player.setNext(wanted)
    }

    /// The player moved on to the successor by itself.
    private func onAdvanced() {
        guard let item = preloaded, let at = snapshot.value.queue.firstIndex(where: { $0.id == item.id }) else { return }
        preloaded = nil
        loadedId = item.id
        pendingPositionMs = 0
        recoveries = 0
        snapshot.update { $0.index = at }
        preload()
        save()
    }

    /// The stream broke while playing: load it again where it stopped, and after a few tries move on.
    private func onPlayerError(_ error: Error) {
        guard let item = snapshot.value.current, item.id == loadedId else { return }
        recoveries += 1
        if recoveries > Self.maxRecoveries {
            log("player error, giving up on '\(item.title)' after \(Self.maxRecoveries) tries: \(error.localizedDescription)")
            problem("Could not play: \(item.title)\n\(Self.cause(error))")
            recoveries = 0
            return step(+1, auto: true)
        }
        log("player error, loading '\(item.title)' again (#\(recoveries)): \(error.localizedDescription)")
        load(item, player.positionMs(), play: true)
    }

    private static func restore(_ saved: SavedQueue?) -> Snapshot {
        guard let saved else { return Snapshot() }
        let queue = Array(saved.queue.prefix(maxQueue))
        return Snapshot(
            queue: queue,
            index: min(max(saved.index, 0), max(0, queue.count - 1)),
            repeatMode: saved.repeatMode == "all" || saved.repeatMode == "one" ? saved.repeatMode : "off",
            finished: saved.finished && !queue.isEmpty
        )
    }

    private static let maxQueue = 200
    private static let maxRecoveries = 3
    private static let prevRestartsAfterMs: Int64 = 3000
}
