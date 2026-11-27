import Foundation

/// What is kept of the personal queue between runs.
struct SavedQueue: Equatable, Codable {
    var queue: [QueueItem] = []
    var index = 0
    var repeatMode = "off"
    /// Where the current item resumes.
    var positionMs: Int64 = 0
    var finished = false
    /// Whether shuffle is on, and the order the queue had when it went on.
    var shuffle = false
    var shuffleOrder: [String] = []
    /// Ids of the songs added to the queue by hand that are still waiting after `index`.
    var queued: [String] = []
    /// Name of the list playing (album, playlist), shown above the songs still to come from it.
    var label: String?

    enum CodingKeys: String, CodingKey {
        case queue, index, positionMs, finished, shuffle, shuffleOrder, queued, label
        case repeatMode = "repeat"
    }

    init(queue: [QueueItem] = [], index: Int = 0, repeatMode: String = "off", positionMs: Int64 = 0, finished: Bool = false,
         shuffle: Bool = false, shuffleOrder: [String] = [], queued: [String] = [], label: String? = nil) {
        self.queue = queue
        self.index = index
        self.repeatMode = repeatMode
        self.positionMs = positionMs
        self.finished = finished
        self.shuffle = shuffle
        self.shuffleOrder = shuffleOrder
        self.queued = queued
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        queue = try values.decodeIfPresent([QueueItem].self, forKey: .queue) ?? []
        index = try values.decodeIfPresent(Int.self, forKey: .index) ?? 0
        repeatMode = try values.decodeIfPresent(String.self, forKey: .repeatMode) ?? "off"
        positionMs = try values.decodeIfPresent(Int64.self, forKey: .positionMs) ?? 0
        finished = try values.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        shuffle = try values.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        shuffleOrder = try values.decodeIfPresent([String].self, forKey: .shuffleOrder) ?? []
        queued = try values.decodeIfPresent([String].self, forKey: .queued) ?? []
        label = try values.decodeIfPresent(String.self, forKey: .label)
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
        /// What is still to come is mixed, and stays mixed as songs are added; off puts the songs back in their order.
        var shuffle = false
        /// The queue ran out: nothing is playing, and play starts it again from the top.
        var finished = false
        /// The current song is on its way to play: the screen shows that something is happening before it is heard.
        var loading = false
        /// Ids of the songs added by hand that are still waiting after `index`; they play before the rest of the list.
        var queued: Set<String> = []
        /// Name of the list playing, or nil when there is none.
        var label: String?

        var current: QueueItem? { queue.indices.contains(index) ? queue[index] : nil }
    }

    /// Something the person should be told about a song: what happened ([kind]), to which ([title]), and what went
    /// wrong ([detail]), for whoever fixes the app.
    struct Problem: Equatable {
        /// The raw value is how the screen knows it.
        enum Kind: String {
            /// Still loading after a while: the network is slow.
            case slow = "load_slow"
            /// Could not load it: the device has no network. Play tries again.
            case offline = "load_offline"
            /// YouTube will not give the song out (removed, private, blocked where the person is): the next song plays instead.
            case skipped = "load_skipped"
            /// The stream kept breaking while it played, which is the connection and not the song: the next song plays instead.
            case broken = "load_broken"
            /// YouTube will not play it, and nothing was skipped to (too many such songs in a row).
            case unplayable = "load_unplayable"
            /// Could not load it, for some other reason (a very slow network, a broken stream). Play tries again.
            case failed = "load_failed"
            case queueFull = "queue_full"
        }

        let kind: Kind
        var title = ""
        var detail = ""
    }

    let snapshot: StateFlow<Snapshot>

    private let scope: Scope
    private let player: PlayerPort
    private let time: TimeSource
    /// Called whenever what should be remembered changed.
    private let persist: (SavedQueue) -> Void
    /// Something the person should be told, e.g. a song that would not load.
    private let problem: (Problem) -> Void
    private let log: (String) -> Void
    /// The queue ran out of songs after the item given (it played through, or next was pressed on the last one).
    private let onQueueEnd: (QueueItem) -> Void
    private let newId: () -> String
    private var random: AnyRandom

    /// Queue item loaded in the player; nil after a restart until something is played.
    private var loadedId: String?

    /// Where the current item resumes once it is loaded.
    private var pendingPositionMs: Int64

    /// The ids of the queue in the order it had when shuffle went on: what turning it off goes back to.
    private var shuffleOrder: [String]

    /// Songs added by hand that have played (or been skipped past): back can reach them, but repeat all leaves them out.
    private var playedQueued = Set<String>()

    /// Item handed to the player as the gapless successor of the loaded one.
    private var preloaded: QueueItem?

    /// A song follows the one loaded, handed to the player to play with no gap.
    var hasSuccessor: Bool { preloaded != nil }
    private var job: Job?

    /// Reloads used on the current item; stops endless retry loops on a broken stream.
    private var recoveries = 0

    /// Songs skipped in a row because they cannot be played; when YouTube breaks for every song, skipping stops.
    private var skippedInARow = 0

    /// Whether the item being loaded starts playing once it is ready; play and pause during a load only flip this.
    private var playOnLoad = false

    /// Says the load is slow once it has taken a while.
    private var slowJob: Job?

    /// What is known about the network, shared with whatever else plays on this device.
    let health: NetworkHealth
    private var watchJob: Job?

    /// Songs whose last load was said to be slow or failed: loading one again starts from a new stream address.
    private var stuckVideoIds = Set<String>()

    init(scope: Scope, player: PlayerPort, saved: SavedQueue?, persist: @escaping (SavedQueue) -> Void,
         problem: @escaping (Problem) -> Void = { _ in }, log: @escaping (String) -> Void = { _ in },
         onQueueEnd: @escaping (QueueItem) -> Void = { _ in }, newId: @escaping () -> String = { UUID().uuidString },
         random: AnyRandom = AnyRandom(), time: TimeSource? = nil, health: NetworkHealth = NetworkHealth()) {
        self.scope = scope
        self.health = health
        self.player = player
        self.time = time ?? SystemTime.shared
        self.persist = persist
        self.problem = problem
        self.log = log
        self.onQueueEnd = onQueueEnd
        self.newId = newId
        self.random = random
        snapshot = StateFlow(LocalSession.restore(saved))
        shuffleOrder = saved?.shuffleOrder ?? []
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
        watchJob?.cancel()
        watchJob = scope.launch { [weak self] in await self?.watchStalls() }
    }

    /// Tells `health` when the player stalls for want of data, so that a weak network is known when listening alone too.
    private func watchStalls() async {
        var since: Int64?
        while true {
            guard await time.wait(ms: Self.stallTickMs) else { return }
            let now = time.nowMs()
            if loadedId != nil, job?.isActive != true, player.isBuffering() {
                if since == nil { since = now }
                continue
            }
            let was = since
            since = nil
            if let was, player.isPlaying(), now - was >= Self.stallMinMs {
                log("stalled for \(now - was)ms")
                if health.onStall(now) { log("weak network") }
            }
            let whole = snapshot.value.current?.durMs ?? 0
            let buffered = player.bufferedPositionMs()
            if health.tick(now, aheadMs: max(buffered - player.positionMs(), 0), fullyLoaded: whole > 0 && buffered >= whole - 1000) {
                log("network is good again")
            }
        }
    }

    /// A room takes the player: silence it, but remember where this queue stood so it can be picked up again.
    func detach() {
        job?.cancel()
        watchJob?.cancel()
        slowJob?.cancel()
        if loadedId != nil { pendingPositionMs = player.positionMs() }
        loadedId = nil
        preloaded = nil
        player.stop()
        snapshot.update { $0.loading = false }
        save()
    }

    // ------------------------------------------------------------------ transport

    func play() {
        let s = snapshot.value
        if loadedId == nil && job?.isActive == true {
            // Asked twice (a button and the lock screen both do): the item is on its way, do not start over
            playOnLoad = true
            snapshot.update { $0.loading = true }
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
        snapshot.update { $0.loading = false }
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
        let s = snapshot.value
        guard let at = s.queue.firstIndex(where: { $0.id == id }) else { return }
        let item = placeTarget(at)
        load(item, 0, play: true)
    }

    /// Moves playback to the song at `target` while keeping the three tiers after the new index in order:
    /// songs in `Snapshot.queued` stay right after the song playing unless the jump is into `Snapshot.queued` itself,
    /// in which case the queued songs before `target` are skipped past and become played.
    private func placeTarget(_ target: Int) -> QueueItem {
        let s = snapshot.value
        let chosen = s.queue[target]
        if s.queued.contains(chosen.id) {
            let dropped = s.queue.prefix(target + 1).compactMap { s.queued.contains($0.id) ? $0.id : nil }
            playedQueued.formUnion(dropped)
            let newQueued = s.queued.subtracting(dropped)
            let queue = s.queue.enumerated().map { i, item -> QueueItem in
                if i <= target && item.auto { var c = item; c.auto = false; return c }
                return item
            }
            snapshot.update { $0.queue = queue; $0.index = target; $0.queued = newQueued; $0.finished = false }
            return queue[target]
        }
        let waiting = s.finished ? [] : s.queue.dropFirst(s.index + 1).filter { s.queued.contains($0.id) }
        let waitingIds = Set(waiting.map(\.id))
        let rest = s.queue.filter { !waitingIds.contains($0.id) }
        let at = rest.firstIndex(where: { $0.id == chosen.id }) ?? 0
        let before = rest.prefix(at + 1).map { item -> QueueItem in
            if item.auto { var c = item; c.auto = false; return c }
            return item
        }
        let after = Array(rest.dropFirst(at + 1))
        let queue = before + waiting + after
        snapshot.update { $0.queue = queue; $0.index = at; $0.queued = waitingIds; $0.finished = false }
        return queue[at]
    }

    // ------------------------------------------------------------------ queue

    /// Adds songs to the queue. By default (`queued` = true) they go into the "Next in queue" group: at the start of it
    /// with `next`, or at the end of it without, and only a song already in that group is left out. With `queued` = false
    /// they extend the list itself (before autoplay songs), or with `auto` = true the autoplay tail at the very end.
    func add(_ tracks: [TrackRef], next: Bool, queued: Bool = true, auto: Bool = false) {
        let s = snapshot.value
        let startNow = s.queue.isEmpty || s.finished
        let fresh: [TrackRef]
        if queued && !auto {
            var seen = startNow ? Set<String>() : Set(s.queue.dropFirst(s.index + 1).filter { s.queued.contains($0.id) }.map(\.videoId))
            fresh = tracks.filter { seen.insert($0.videoId).inserted }
        } else {
            fresh = Queues.fresh(tracks, queue: s.queue, index: s.finished ? s.queue.count : s.index)
        }
        let room = Self.maxQueue - s.queue.count
        if !fresh.isEmpty && room <= 0 { return problem(Problem(kind: .queueFull)) }
        let items = fresh.prefix(max(room, 0)).enumerated().map { i, t in
            QueueItem(id: newId(), videoId: t.videoId, title: t.title, artist: t.artist, thumb: t.thumb, durMs: t.durMs,
                      addedBy: "", auto: auto && !(startNow && i == 0), explicit: t.explicit, year: t.year)
        }
        guard let first = items.first else { return }

        if startNow {
            let old = s.queue.map { item -> QueueItem in
                if item.auto { var c = item; c.auto = false; return c }
                return item
            }
            let queue = old + items
            if s.shuffle && !auto { shuffleOrder += items.map(\.id) }
            snapshot.update { $0.queue = queue; $0.index = old.count; $0.queued = []; $0.finished = false }
            load(first, 0, play: true)
            save()
            return
        }

        var queue = s.queue
        var newQueued = s.queued
        if queued && !auto {
            let at = min(max(next ? s.index + 1 : s.index + 1 + s.queued.count, 0), queue.count)
            queue.insert(contentsOf: items, at: at)
            newQueued.formUnion(items.map(\.id))
        } else if auto {
            queue.append(contentsOf: items)
        } else {
            let autoStart = ((s.index + 1)..<queue.count).first { queue[$0].auto } ?? queue.count
            let contextStart = min(s.index + 1 + s.queued.count, autoStart)
            if s.shuffle && !next {
                shuffleOrder += items.map(\.id)
                var end = autoStart
                for item in items {
                    queue.insert(item, at: Int.random(in: contextStart...end, using: &random))
                    end += 1
                }
            } else {
                queue.insert(contentsOf: items, at: next ? contextStart : autoStart)
            }
        }
        snapshot.update { $0.queue = queue; $0.queued = newQueued }
        preload()
        save()
    }

    /// Makes `tracks`, a list the person chose a song from, the active list and plays song `start` of it, keeping any
    /// unplayed songs added by hand (`Snapshot.queued`) right after that song. With shuffle on, that song is first,
    /// the queued songs follow, and the rest of the list is mixed behind them.
    func playList(_ tracks: [TrackRef], start: Int, label: String? = nil) {
        let s = snapshot.value
        let waiting = s.finished ? [] : s.queue.dropFirst(s.index + 1).filter { s.queued.contains($0.id) }
        let cap = max(Self.maxQueue - waiting.count, 0)
        let items = tracks.prefix(cap).map {
            QueueItem(id: newId(), videoId: $0.videoId, title: $0.title, artist: $0.artist, thumb: $0.thumb, durMs: $0.durMs,
                      addedBy: "", explicit: $0.explicit, year: $0.year)
        }
        guard !items.isEmpty else { return }
        let first = min(max(start, 0), items.count - 1)
        let chosen = items[first]
        let shuffle = s.shuffle
        let queue: [QueueItem]
        if shuffle {
            var rest = items
            rest.remove(at: first)
            rest.shuffle(using: &random)
            queue = [chosen] + waiting + rest
        } else {
            queue = Array(items.prefix(first + 1)) + waiting + Array(items.dropFirst(first + 1))
        }
        let newIndex = shuffle ? 0 : first
        let newQueued = Set(waiting.map(\.id))
        shuffleOrder = shuffle ? items.map(\.id) : []
        playedQueued.removeAll()
        skippedInARow = 0 // a new list is a new start
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = (trimmed?.isEmpty == false) ? trimmed : nil
        // What plays carries on until the new song is ready, as when a song of the queue is chosen
        snapshot.update { $0.queue = queue; $0.index = newIndex; $0.queued = newQueued; $0.label = cleanLabel; $0.finished = false }
        load(chosen, 0, play: true)
        save()
    }

    /// Removes only the songs added to the queue by hand ("Next in queue"), leaving the playing list untouched.
    func clearQueued() {
        let s = snapshot.value
        if s.queued.isEmpty { return }
        let queue = s.queue.filter { !s.queued.contains($0.id) }
        snapshot.update { $0.queue = queue; $0.queued = [] }
        preload()
        save()
    }

    func remove(_ id: String) {
        let s = snapshot.value
        guard let at = s.queue.firstIndex(where: { $0.id == id }) else { return }
        var queue = s.queue
        queue.remove(at: at)
        var newQueued = s.queued
        newQueued.remove(id)
        playedQueued.remove(id)
        if !shuffleOrder.isEmpty { shuffleOrder.removeAll { $0 == id } }
        if at < s.index {
            snapshot.update { $0.queue = queue; $0.index = s.index - 1; $0.queued = newQueued }
        } else if at > s.index {
            snapshot.update { $0.queue = queue; $0.queued = newQueued }
        } else if queue.isEmpty {
            stopPlayer()
            playedQueued.removeAll()
            let repeatMode = snapshot.value.repeatMode
            let shuffle = snapshot.value.shuffle
            snapshot.set(Snapshot(repeatMode: repeatMode, shuffle: shuffle))
        } else if at < queue.count {
            // The next song takes the place of the one removed, and plays if that one was playing
            let play = loadedId == id && player.isPlaying()
            let nextItem = queue[at]
            if newQueued.remove(nextItem.id) != nil {
                playedQueued.insert(nextItem.id)
            }
            if nextItem.auto { queue[at].auto = false }
            snapshot.update { $0.queue = queue; $0.queued = newQueued }
            if loadedId == id { load(queue[at], 0, play: play) } else { pendingPositionMs = 0 }
        } else {
            stopPlayer()
            snapshot.update { $0.queue = queue; $0.index = queue.count - 1; $0.queued = []; $0.finished = true }
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
        item.explicit = track.explicit
        item.year = track.year
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

    /// Moves item `id` to `toIndex`. When `queued` is given, the song also joins (or leaves) the "Next in queue" group
    /// according to the group it was dropped into; the three tiers after `Snapshot.index` are always kept in order.
    func move(_ id: String, toIndex: Int, queued: Bool? = nil) {
        let s = snapshot.value
        guard let from = s.queue.firstIndex(where: { $0.id == id }) else { return }
        let currentId = s.current?.id
        var list = s.queue
        let moved = list.remove(at: from)
        list.insert(moved, at: min(max(toIndex, 0), list.count))
        let index = currentId.flatMap { current in list.firstIndex { $0.id == current } } ?? 0
        let landed = list.firstIndex(where: { $0.id == id }) ?? 0
        var newQueued = s.queued
        if s.finished || landed <= index {
            newQueued.remove(id)
        } else if queued == true {
            newQueued.insert(id)
            playedQueued.remove(id)
            if list[landed].auto { list[landed].auto = false }
        } else if queued == false {
            newQueued.remove(id)
            playedQueued.remove(id)
            if list[landed].auto { list[landed].auto = false }
            if s.shuffle && !shuffleOrder.contains(id) { shuffleOrder.append(id) }
        }
        let queue = Self.normalize(list, index: index, queuedIds: s.finished ? [] : newQueued, finished: s.finished)
        let keptQueued = s.finished ? Set<String>() : Set(queue.dropFirst(index + 1).compactMap { newQueued.contains($0.id) ? $0.id : nil })
        snapshot.update { $0.queue = queue; $0.index = index; $0.queued = keptQueued }
        preload()
        save()
    }

    /// Takes up to [count] of the oldest songs off the queue, the ones already played, to make room at the end: never the
    /// song playing, and never one still to come. Once the queue has finished all of it has been played.
    func dropPlayed(_ count: Int) {
        let s = snapshot.value
        let drop = min(count, s.finished ? s.queue.count : s.index)
        guard drop > 0 else { return }
        let dropped = Set(s.queue.prefix(drop).map(\.id))
        playedQueued.subtract(dropped)
        snapshot.update { $0.queue = Array($0.queue.dropFirst(drop)); $0.index = max($0.index - drop, 0) }
        save()
    }

    func clear() {
        stopPlayer()
        skippedInARow = 0 // a new list is a new start
        playedQueued.removeAll()
        shuffleOrder = []
        let repeatMode = snapshot.value.repeatMode
        let shuffle = snapshot.value.shuffle
        snapshot.set(Snapshot(repeatMode: repeatMode, shuffle: shuffle))
        save()
    }

    /// Mixes up what is still to come of the list, so the song playing carries on and any songs added by hand keep their
    /// order ahead of it. Once the queue has finished it mixes the whole list and plays from the top.
    func shuffle() {
        let s = snapshot.value
        if s.queue.count < 2 { return }
        if s.finished {
            var queue = s.queue
            queue.shuffle(using: &random)
            snapshot.update { $0.queue = queue }
            load(queue[0], 0, play: true)
        } else {
            let before = Array(s.queue.prefix(s.index + 1))
            let after = Array(s.queue.dropFirst(s.index + 1))
            let waiting = after.filter { s.queued.contains($0.id) }
            var context = after.filter { !s.queued.contains($0.id) && !$0.auto }
            context.shuffle(using: &random)
            let auto = after.filter(\.auto)
            snapshot.update { $0.queue = before + waiting + context + auto }
            preload()
        }
        save()
    }

    /// Shuffle as a mode, like the room's: on remembers the order of the list and mixes what is still to come of it
    /// (leaving songs added by hand in the order they were added); off puts the list's songs back in that order.
    func setShuffle(_ on: Bool) {
        let s = snapshot.value
        if on == s.shuffle { return }
        let queue: [QueueItem]
        if s.finished {
            shuffleOrder = on ? s.queue.filter { !s.queued.contains($0.id) && !$0.auto }.map(\.id) : []
            queue = s.queue
        } else {
            let before = Array(s.queue.prefix(s.index + 1))
            let after = Array(s.queue.dropFirst(s.index + 1))
            let waiting = after.filter { s.queued.contains($0.id) }
            let context = after.filter { !s.queued.contains($0.id) && !$0.auto }
            let auto = after.filter(\.auto)
            let mixed: [QueueItem]
            if on {
                shuffleOrder = s.queue.filter { !s.queued.contains($0.id) && !$0.auto }.map(\.id)
                var c = context
                c.shuffle(using: &random)
                mixed = c
            } else {
                var rank: [String: Int] = [:]
                for (i, id) in shuffleOrder.enumerated() { rank[id] = i }
                shuffleOrder = []
                mixed = context.enumerated().sorted {
                    let a = rank[$0.element.id] ?? Int.max, b = rank[$1.element.id] ?? Int.max
                    return a != b ? a < b : $0.offset < $1.offset
                }.map(\.element)
            }
            queue = before + waiting + mixed + auto
        }
        snapshot.update { $0.shuffle = on; $0.queue = queue }
        preload()
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
        let orderedQueued = s.queue.dropFirst(s.index + 1).compactMap { s.queued.contains($0.id) ? $0.id : nil }
        persist(SavedQueue(queue: s.queue, index: s.index, repeatMode: s.repeatMode, positionMs: position, finished: s.finished,
                           shuffle: s.shuffle, shuffleOrder: shuffleOrder, queued: orderedQueued, label: s.label))
    }

    /// The queue as another device can take it over (Connect), and how many songs were left out because only this device has them.
    struct Handover: Equatable {
        var saved: SavedQueue
        var dropped: Int
    }

    /// What this queue is now, to hand over to another device: `save` with the songs of this device's own music (`local:`) taken
    /// out, since the other device has no such file. The index follows the song that was playing (the next one when that was
    /// one of them), and the queued group and the shuffle order keep only what is left.
    func exportQueue() -> Handover {
        let s = snapshot.value
        let position = loadedId != nil ? player.positionMs() : pendingPositionMs
        let orderedQueued = s.queue.dropFirst(s.index + 1).compactMap { s.queued.contains($0.id) ? $0.id : nil }
        let whole = SavedQueue(queue: s.queue, index: s.index, repeatMode: s.repeatMode, positionMs: position, finished: s.finished,
                               shuffle: s.shuffle, shuffleOrder: shuffleOrder, queued: orderedQueued, label: s.label)
        let kept = s.queue.filter { !LocalMusic.isLocal($0.videoId) }
        if kept.count == s.queue.count { return Handover(saved: whole, dropped: 0) }
        let keptIds = Set(kept.map(\.id))
        let current = s.index < s.queue.count ? s.queue[s.index] : nil
        let atCurrent = current.map { keptIds.contains($0.id) } ?? false
        let index: Int
        if let current, atCurrent {
            index = kept.firstIndex { $0.id == current.id } ?? 0
        } else if let next = s.queue.dropFirst(s.index + 1).first(where: { keptIds.contains($0.id) }) {
            // The song that was playing is gone: the next one that stays, from the start
            index = kept.firstIndex { $0.id == next.id } ?? 0
        } else {
            index = max(0, kept.count - 1)
        }
        var out = whole
        out.queue = kept
        out.index = index
        out.positionMs = atCurrent ? position : 0
        out.finished = s.finished && !kept.isEmpty
        out.shuffleOrder = shuffleOrder.filter { keptIds.contains($0) }
        out.queued = orderedQueued.filter { keptIds.contains($0) }
        return Handover(saved: out, dropped: s.queue.count - kept.count)
    }

    /// Takes `saved` (what another device handed over) as the whole queue, where it stood: whatever played here stops. With
    /// `play` the song starts from its position; without it the queue waits, as one that was restored does.
    func importQueue(_ saved: SavedQueue, play shouldPlay: Bool) {
        stopPlayer()
        recoveries = 0
        skippedInARow = 0
        playOnLoad = false
        playedQueued.removeAll()
        stuckVideoIds.removeAll()
        shuffleOrder = saved.shuffleOrder
        pendingPositionMs = saved.finished ? 0 : saved.positionMs
        snapshot.set(LocalSession.restore(saved))
        save()
        if shouldPlay { play() }
    }

    // ------------------------------------------------------------------ playing

    /// Moves [delta] items along the queue; at the ends it wraps when repeating all, and otherwise stops.
    private func step(_ delta: Int, auto: Bool) {
        let s = snapshot.value
        if s.queue.isEmpty { return }
        if auto && s.repeatMode == "one" {
            load(s.queue[s.index], 0, play: true)
            return
        }
        var target = s.finished && delta < 0 ? s.index : s.index + delta
        if target >= s.queue.count {
            if s.repeatMode != "all" { return finish() }
            // Repeat all loops the list: songs added by hand that already played once do not play a second time
            let contextOnly = s.queue.filter { !playedQueued.contains($0.id) }
            if !contextOnly.isEmpty && contextOnly.count < s.queue.count {
                playedQueued.removeAll()
                snapshot.update { $0.queue = contextOnly; $0.index = 0; $0.queued = []; $0.finished = false }
                load(contextOnly[0], 0, play: true)
                return
            }
            target = 0
        }
        if target < 0 {
            if delta < 0 { target = 0 } else { return finish() }
        }
        let item = placeTarget(target)
        load(item, 0, play: true)
    }

    /// Ran out of songs: nothing is current until play starts the list again.
    private func finish() {
        let last = snapshot.value.queue.last
        stopPlayer()
        snapshot.update {
            $0.queue = $0.queue.map { item in
                if item.auto { var c = item; c.auto = false; return c }
                return item
            }
            $0.index = max($0.queue.count - 1, 0)
            $0.queued = []
            $0.finished = true
        }
        save()
        if let last { onQueueEnd(last) }
    }

    private func stopPlayer() {
        job?.cancel()
        slowJob?.cancel()
        player.stop()
        loadedId = nil
        preloaded = nil
        pendingPositionMs = 0
        snapshot.update { $0.loading = false }
    }

    private func load(_ item: QueueItem, _ positionMs: Int64, play: Bool) {
        // The tries are counted for the song, not its place: a new song where the last one was starts from none
        if item.id != loadedId { recoveries = 0 }
        job?.cancel()
        slowJob?.cancel()
        preloaded = nil
        loadedId = nil
        let s = snapshot.value
        guard let at = s.queue.firstIndex(where: { $0.id == item.id }) else { return }
        var newQueued = s.queued
        if newQueued.remove(item.id) != nil {
            playedQueued.insert(item.id)
        }
        var queue = s.queue
        if queue[at].auto { queue[at].auto = false }
        let loaded = queue[at]
        // The person sees the new song at once, and that it is on its way, not only when it has loaded
        snapshot.update { $0.queue = queue; $0.index = at; $0.queued = newQueued; $0.finished = false; $0.loading = play }
        playOnLoad = play
        let again = stuckVideoIds.contains(loaded.videoId)
        // A load that takes long is said to be slow, so that waiting does not look like nothing happening
        slowJob = scope.launch { [weak self] in
            try await self?.time.sleep(ms: Self.slowLoadMs)
            guard let self, self.playOnLoad else { return }
            self.stuckVideoIds.insert(loaded.videoId)
            self.problem(Problem(kind: .slow, title: loaded.title))
        }
        job = scope.launch { [weak self] in
            guard let self else { return }
            var retried = false
            while true {
                do {
                    if again || retried { await self.player.refresh(loaded.videoId) }
                    try await self.player.prepare(loaded, seekToMs: positionMs)
                    self.slowJob?.cancel()
                    self.stuckVideoIds.remove(loaded.videoId)
                    self.loadedId = loaded.id
                    self.pendingPositionMs = 0
                    self.skippedInARow = 0
                    self.snapshot.update { $0.loading = false }
                    if self.playOnLoad { self.player.play() }
                    self.preload()
                    self.save()
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    self.log("could not load '\(loaded.title)': \(error.localizedDescription)")
                    // Nothing goes on loading in the background, and nothing starts later by itself
                    self.player.stop()
                    // A failure that is neither "YouTube will not give it out" nor "no network" is often a blip: the person
                    // who wants to hear the song gets one more try from a new stream address before it counts as failed
                    if !retried, (error as? LoadFailure) == nil, self.playOnLoad {
                        retried = true
                        self.log("trying '\(loaded.title)' once more in \(Self.retryAfterMs)ms")
                        try await self.time.sleep(ms: Self.retryAfterMs)
                        if self.playOnLoad { continue }
                        // Paused meanwhile: there is nothing to tell, and play starts from a new address
                        self.slowJob?.cancel()
                        self.stuckVideoIds.insert(loaded.videoId)
                        self.pendingPositionMs = positionMs
                        self.snapshot.update { $0.loading = false }
                        return
                    }
                    self.slowJob?.cancel()
                    self.stuckVideoIds.insert(loaded.videoId)
                    self.pendingPositionMs = positionMs
                    self.snapshot.update { $0.loading = false }
                    self.loadFailed(loaded, error)
                    return
                }
            }
        }
    }

    /// Tells the person why [item] did not load. A song YouTube will not play is skipped, as music apps do, but only a
    /// few in a row: when every song fails, YouTube changed something, and running through the queue would not help.
    private func loadFailed(_ item: QueueItem, _ error: Error) {
        let detail = Self.cause(error)
        switch (error as? LoadFailure)?.reason {
        case .offline:
            problem(Problem(kind: .offline, title: item.title, detail: detail))
        case .unplayable:
            skippedInARow += 1
            if skippedInARow < Self.maxSkippedInARow {
                problem(Problem(kind: .skipped, title: item.title, detail: detail))
                step(+1, auto: false)
            } else {
                skippedInARow = 0
                problem(Problem(kind: .unplayable, title: item.title, detail: detail))
            }
        case nil:
            skippedInARow += 1
            if playOnLoad, hasNext(), skippedInARow < Self.maxSkippedInARow {
                // Tried twice, and the person wants to hear music: on to the next song, which is not why it was to stop
                problem(Problem(kind: .broken, title: item.title, detail: detail))
                step(+1, auto: false)
            } else {
                skippedInARow = 0
                problem(Problem(kind: .failed, title: item.title, detail: detail))
            }
        }
    }

    /// Whether there is a song to go on to. With none (the last of the list, or the only one) a failure stops: going on
    /// would end the queue, and that starts what follows it (autoplay) because of a network that is not there.
    private func hasNext() -> Bool {
        let s = snapshot.value
        return s.index + 1 < s.queue.count || (s.repeatMode == "all" && s.queue.count > 1)
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
        let s = snapshot.value
        guard let item = preloaded, let at = s.queue.firstIndex(where: { $0.id == item.id }) else { return }
        preloaded = nil
        loadedId = item.id
        pendingPositionMs = 0
        recoveries = 0
        var newQueued = s.queued
        if newQueued.remove(item.id) != nil {
            playedQueued.insert(item.id)
        }
        var queue = s.queue
        if queue[at].auto { queue[at].auto = false }
        snapshot.update { $0.queue = queue; $0.index = at; $0.queued = newQueued }
        preload()
        save()
    }

    /// The stream broke while playing: load it again where it stopped, and after a few tries move on.
    private func onPlayerError(_ error: Error) {
        guard let item = snapshot.value.current, item.id == loadedId else { return }
        recoveries += 1
        if recoveries > Self.maxRecoveries {
            log("player error, giving up on '\(item.title)' after \(Self.maxRecoveries) tries: \(error.localizedDescription)")
            problem(Problem(kind: .broken, title: item.title, detail: Self.cause(error)))
            recoveries = 0
            // Not "auto": repeating this one song would load the broken stream again and again
            return step(+1, auto: false)
        }
        log("player error, loading '\(item.title)' again (#\(recoveries)): \(error.localizedDescription)")
        load(item, player.positionMs(), play: true)
    }

    private static func normalize(_ list: [QueueItem], index: Int, queuedIds: Set<String>, finished: Bool) -> [QueueItem] {
        if list.isEmpty { return list }
        if finished {
            return list.map { item in
                if item.auto { var c = item; c.auto = false; return c }
                return item
            }
        }
        let before = list.prefix(index + 1).map { item -> QueueItem in
            if item.auto { var c = item; c.auto = false; return c }
            return item
        }
        let after = list.dropFirst(index + 1)
        let tierQueued = after.filter { queuedIds.contains($0.id) }.map { item -> QueueItem in
            if item.auto { var c = item; c.auto = false; return c }
            return item
        }
        let tierContext = after.filter { !queuedIds.contains($0.id) && !$0.auto }
        let tierAuto = after.filter { !queuedIds.contains($0.id) && $0.auto }
        return before + tierQueued + tierContext + tierAuto
    }

    private static func restore(_ saved: SavedQueue?) -> Snapshot {
        guard let saved else { return Snapshot() }
        let raw = Array(saved.queue.prefix(maxQueue))
        let index = min(max(saved.index, 0), max(0, raw.count - 1))
        let finished = saved.finished && !raw.isEmpty
        let afterIds = finished ? Set<String>() : Set(raw.dropFirst(index + 1).map(\.id))
        let queued = finished ? Set<String>() : Set(saved.queued.filter { afterIds.contains($0) })
        let queue = normalize(raw, index: index, queuedIds: queued, finished: finished)
        let trimmed = saved.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (trimmed?.isEmpty == false && !queue.isEmpty) ? trimmed : nil
        return Snapshot(
            queue: queue,
            index: index,
            repeatMode: saved.repeatMode == "all" || saved.repeatMode == "one" ? saved.repeatMode : "off",
            shuffle: saved.shuffle,
            finished: finished,
            queued: queued,
            label: label
        )
    }

    /// What the queue outside a room holds. A room's holds 200 (`MAX_QUEUE` in `server/src/room.ts`); `queueMax` in `room_controller.dart` says both.
    static let maxQueue = 1000
    private static let maxRecoveries = 3
    private static let maxSkippedInARow = 3
    private static let prevRestartsAfterMs: Int64 = 3000
    /// A load that takes longer than this is said to be slow.
    private static let slowLoadMs: Int64 = 8000

    /// A song that did not load gets one more try after this long, from a new stream address.
    static let retryAfterMs: Int64 = 3000
    private static let stallTickMs: Int64 = 500
    private static let stallMinMs: Int64 = 1000
}
