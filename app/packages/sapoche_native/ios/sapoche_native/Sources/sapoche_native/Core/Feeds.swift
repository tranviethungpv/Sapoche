import Foundation

/// What to offer to play. YouTube lists related songs beside any song, so suggestions come from a few songs the person
/// loves most (the seeds, chosen by [Taste] from what they heard, liked and left after a few seconds). The lists are
/// kept for [freshMs], so opening the app shows them at once, even offline, and the network is only used to renew them.
actor SuggestionFeed {
    static let offerCount = 5
    static let forYouCount = 30
    static let discoverCount = 20
    static let contextCount = 20
    static let seedCount = 8
    static let freshMs: Int64 = 12 * 60 * 60 * 1000
    /// Songs looked at for each one that is given, so ranking has a choice.
    private static let poolFactor = 4
    static let statsMs: Int64 = 30 * 24 * 60 * 60 * 1000
    static let song = "song"
    static let artist = "artist"
    private static let recentMs: Int64 = 7 * 24 * 60 * 60 * 1000
    /// When the radios hold nothing but songs heard this week, songs heard longer ago than this are given again.
    private static let tiredMs: Int64 = 60 * 60 * 1000

    private let store: LibraryStore
    private let resolver: StreamResolver
    private let music: MusicFeed
    private let now: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    private let renewing = AsyncMutex()

    init(store: LibraryStore, resolver: StreamResolver, music: MusicFeed,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.resolver = resolver
        self.music = music
        self.now = now
        self.log = log
    }

    /// What the library says about the person, as of now.
    private func loadTaste() async throws -> Taste {
        let marks = try await store.tasteMarks()
        // The songs a new person started with count as heard when they were chosen
        let starters = marks.filter { $0.kind == TasteMarks.starter }.compactMap { TasteMarks.starter(label: $0.label, at: $0.at) }
        let heard = try await store.listens().map { Stamped(track: $0.track, at: $0.at, weight: ListenSource.weight($0.source)) } + starters
        let liked = try await store.liked().map { Stamped(track: $0.track, at: $0.at) }
        let skipped = try await store.skipped().map { Stamped(track: $0.track, at: $0.at, weight: ListenSource.weight($0.source)) }
        return Taste(heard: heard, liked: liked, skipped: skipped, now: now(),
                     quietSongs: Set(marks.filter { $0.kind == TasteMarks.quietSong }.map(\.key)),
                     quietArtists: Set(marks.filter { $0.kind == TasteMarks.quietArtist }.map(\.key)))
    }

    private func blocklist() async throws -> Blocklist {
        let blocked = try await store.blocked()
        return Blocklist(songs: Set(blocked.filter { $0.kind == Self.song }.map(\.key)),
                         artists: Set(blocked.filter { $0.kind == Self.artist }.map(\.key)))
    }

    /// The lists kept for [seeds], the best loved seed first; a seed without a list is left out.
    private func kept(_ seeds: [String]) async throws -> [[TrackRef]] {
        var lists: [[TrackRef]] = []
        for seed in seeds {
            if let cached = try await store.cachedSuggestions(seed) { lists.append(cached.tracks) }
        }
        return lists
    }

    /// Songs to offer, from what is kept; nothing until there are seeds and their lists were fetched once.
    func forYou(limit: Int = SuggestionFeed.forYouCount) async throws -> [TrackRef] {
        let taste = try await loadTaste()
        let block = try await blocklist()
        let seeds = taste.seeds(Self.seedCount, block: block)
        return Suggestions.compose(try await kept(seeds), taste: taste, block: block, exclude: try await known(seeds), limit: limit)
    }

    /// Songs by artists the person does not know yet, from what is kept: something new to try.
    func discover(limit: Int = SuggestionFeed.discoverCount) async throws -> [TrackRef] {
        let taste = try await loadTaste()
        let block = try await blocklist()
        let seeds = taste.seeds(Self.seedCount, block: block)
        return Suggestions.discover(try await kept(seeds), taste: taste, block: block, exclude: try await known(seeds), limit: limit)
    }

    /// Fetches again the lists of the seeds whose list is missing or older than [freshMs], or all of them with [force].
    /// One failed seed does not stop the others; what was kept for it stays. Returns whether anything changed.
    func renew(force: Bool) async throws -> Bool {
        try await renewing.withLock { try await self.renewSeeds(force: force) }
    }

    private func renewSeeds(force: Bool) async throws -> Bool {
        let taste = try await loadTaste()
        let block = try await blocklist()
        let seeds = taste.seeds(Self.seedCount, block: block)
        var changed = false
        for seed in seeds {
            if try await fetch(seed, force: force) { changed = true }
        }
        // The lists behind the mixes for each time of day stay too, so they are there when that time comes
        let context = Taste.buckets.flatMap { taste.contextSeeds($0, block: block).map(\.videoId) }
        try await store.keepSuggestionsFor(seeds + context)
        return changed
    }

    /// Fetches the radio of [seed] and keeps it, unless a fresh one is kept (and not forced). False when nothing changed.
    private func fetch(_ seed: String, force: Bool) async throws -> Bool {
        let kept = try await store.cachedSuggestions(seed)
        if !force, let kept, now() - kept.fetchedAt < Self.freshMs { return false }
        do {
            let songs = try await radioOf(seed).filter(Suggestions.isSong)
            try await store.putSuggestions(seed, songs, at: now())
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("could not fetch suggestions for \(seed): \(error.localizedDescription)")
            return false
        }
    }

    /// How the songs of each source fared in the last `statsMs`: heard, and left after a few seconds.
    func sourceStats() async throws -> [LibraryStore.SourceStats] {
        try await store.sourceStats(since: now() - Self.statsMs)
    }

    /// The songs kept for each seed, for the screens that say "because you listened to".
    func seedLists() async throws -> [(seed: String, tracks: [TrackRef])] {
        let seeds = try await loadTaste().seeds(Self.seedCount, block: try await blocklist())
        var lists: [(seed: String, tracks: [TrackRef])] = []
        for seed in seeds {
            if let cached = try await store.cachedSuggestions(seed) { lists.append((seed, cached.tracks)) }
        }
        return lists
    }

    /// A mix for this time of day: the songs the person plays at this hour, then what YouTube lists beside them. The part
    /// of the day and the songs, empty until enough was heard at this hour to say anything. A list that was not kept
    /// yet is fetched, so this may need the network.
    func contextMix(limit: Int = SuggestionFeed.contextCount) async throws -> (bucket: String, tracks: [TrackRef]) {
        let taste = try await loadTaste()
        let block = try await blocklist()
        let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(now()) / 1000))
        let bucket = Taste.bucketOf(hour)
        let seeds = taste.contextSeeds(bucket, block: block)
        if seeds.isEmpty { return (bucket, []) }
        for seed in seeds { _ = try await fetch(seed.videoId, force: false) }
        let ids = seeds.map(\.videoId)
        let more = Suggestions.compose(try await kept(ids), taste: taste, block: block, exclude: Set(ids), limit: limit)
        return (bucket, Array((seeds + more).prefix(limit)))
    }

    /// Up to [count] songs to carry on with after [videoId], other than [exclude], what was heard lately and what the
    /// person does not want: the radio YouTube Music makes of the song, or what YouTube lists beside it when that cannot
    /// be had. Needs the network.
    func after(_ videoId: String, exclude: Set<String>, count: Int) async throws -> [TrackRef] {
        try await afterMany([videoId], exclude: exclude, count: count)
    }

    /// Up to [count] songs to carry on with after the [seeds] together, as `after` does for one: the radio of each seed,
    /// taken in turns so no seed crowds out the others. A seed whose radio cannot be had is left out, so the others still
    /// count.
    func afterMany(_ seeds: [String], exclude: Set<String>, count: Int) async throws -> [TrackRef] {
        let taste = try await loadTaste()
        let block = try await blocklist()
        let heard = try await store.heardSince(now() - Self.recentMs)
        var lists: [[TrackRef]] = []
        for (at, seed) in seeds.enumerated() {
            do {
                lists.append(try await radioOf(seed))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The first seed is the one asked for: with nothing for it the caller says so
                if at == 0 && seeds.count == 1 { throw error }
                log("no radio for \(seed): \(error.localizedDescription)")
            }
        }
        var pool = Suggestions.mix(lists, exclude: exclude.union(seeds).union(heard), limit: count * Self.poolFactor) {
            Suggestions.welcome($0, taste: taste, block: block)
        }
        if pool.isEmpty && lists.contains(where: { !$0.isEmpty }) {
            // Radios that give nothing new this week would leave the music at a stop: what was not heard in the last hour
            // will do, by any artist but those the person blocked
            log("nothing new in the radios of \(seeds.count) seeds, taking what was not heard in the last hour")
            let tired = try await store.heardSince(now() - Self.tiredMs)
            pool = Suggestions.mix(lists, exclude: exclude.union(seeds).union(tired), limit: count * Self.poolFactor) {
                Suggestions.isSong($0) && block.allows($0)
            }
        }
        // YouTube's order, put in the order that suits this person
        return Array(Suggestions.rank(pool, taste: taste).prefix(count))
    }

    /// The songs this person offers a room's autoplay to start from; never a song of a file, of an artist they asked for less
    /// of, or a song they asked not to count.
    func offer() async throws -> [TrackRef] {
        let taste = try await loadTaste()
        return taste.offer(Self.offerCount, block: try await blocklist())
    }

    /// What the listening says about the person: how much each artist and each song is loved, and how each source fared.
    func profile() async throws -> (artists: [ArtistScore], songs: [String: Double], marks: [LibraryStore.TasteMark], stats: [LibraryStore.SourceStats]) {
        let taste = try await loadTaste()
        return (taste.artistScores(), taste.songScores(), try await store.tasteMarks(), try await sourceStats())
    }

    /// The radio YouTube Music makes of the song, or what YouTube lists beside it when that cannot be had.
    private func radioOf(_ videoId: String) async throws -> [TrackRef] {
        var radio: [TrackRef] = []
        do {
            radio = try await music.watchNext(videoId).tracks.map(\.ref)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("no radio for \(videoId), using the related list: \(error.localizedDescription)")
        }
        if !radio.isEmpty { return radio }
        return try await resolver.related(videoId, limit: 25).map(\.ref)
    }

    /// Songs not worth offering: the seeds themselves, those liked and those heard this week.
    private func known(_ seeds: [String]) async throws -> Set<String> {
        try await Set(seeds).union(store.likedIds()).union(store.heardSince(now() - Self.recentMs))
    }
}

/// Works through the list of songs to download, one at a time. Which songs to take is decided by the list's state:
/// the ones asked for ([LibraryStore.queued]) any time, the ones that wait for Wi-Fi and a charger
/// ([LibraryStore.waiting]) only when whoever calls knows those are there.
actor Downloader {
    /// [retryLater]: a song failed but has tries left, so the job should be run again after a while.
    struct Result: Equatable {
        let done: Int
        let retryLater: Bool
    }

    /// How the run in hand stands: [active] is the song being fetched, nil when none is. [total] is what the run has taken
    /// so far and what is still to take, so it grows when songs are added meanwhile. A run that is over keeps its numbers
    /// (nil [active], [total] above zero) until the next run starts; [idle] is no run at all.
    struct Batch: Equatable, Sendable {
        let active: String?
        let done: Int
        let total: Int
        let failed: Int
        static let idle = Batch(active: nil, done: 0, total: 0, failed: 0)
    }

    private let store: LibraryStore
    /// Brings the whole song onto the phone and gives back its size in bytes; throws when it cannot.
    private let fetch: @Sendable (String) async throws -> Int64
    private let log: @Sendable (String) -> Void
    /// The phone has a working internet connection (not only a network): asked after a song failed, to tell why.
    private let online: @Sendable () -> Bool
    /// Waits this many milliseconds; a test makes it instant.
    private let pause: @Sendable (Int64) async throws -> Void
    /// Told whenever [progress] changes.
    private let onProgress: @Sendable (Batch) -> Void
    private(set) var progress = Batch.idle {
        didSet { if progress != oldValue { onProgress(progress) } }
    }

    /// A hiccup is tried again after these pauses (milliseconds) before it counts as a failed try.
    static let quickRetryMs: [Int64] = [2_000, 6_000]

    init(store: LibraryStore, fetch: @escaping @Sendable (String) async throws -> Int64, log: @escaping @Sendable (String) -> Void = { _ in },
         online: @escaping @Sendable () -> Bool = { true },
         pause: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
         onProgress: @escaping @Sendable (Batch) -> Void = { _ in }) {
        self.store = store
        self.fetch = fetch
        self.log = log
        self.online = online
        self.pause = pause
        self.onProgress = onProgress
    }

    /// Why a song did not come: what to do about it differs.
    private enum Why {
        /// YouTube will not give it out, and will not on any try.
        case unavailable
        /// There is no room on the phone for it: no other song will fit either, and trying again is no use until room is made.
        case noSpace
        /// There is no internet: it is not the song's fault, so no try is used up, and the other songs would fail as well.
        case offline
        /// A hiccup of the network or of YouTube's: worth another go in a moment.
        case transient
    }

    private func why(_ error: Error) -> Why {
        let reason = (error as? LoadFailure)?.reason
        if reason == .unplayable { return .unavailable }
        if Self.noSpace(error) { return .noSpace }
        if reason == .offline || !online() { return .offline }
        return .transient
    }

    /// The phone has no room: what the file system says (the Cocoa error for a write with no room, `ENOSPC`, or the words of
    /// either), however deep the error was wrapped.
    static func noSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let e = current else { return false }
            if e.domain == NSCocoaErrorDomain && e.code == 640 { return true } // NSFileWriteOutOfSpaceError
            if e.domain == NSPOSIXErrorDomain && e.code == 28 { return true } // ENOSPC
            if e.localizedDescription.range(of: "No space left on device", options: .caseInsensitive) != nil { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Brings the song, going on at once with a pause between two or three times when the failure was a hiccup (what was
    /// written is kept, so each try goes on from there), before it counts as a failed try of the song.
    private func fetchPatiently(_ videoId: String) async throws -> Int64 {
        var tried = 0
        while true {
            do {
                return try await fetch(videoId)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if tried >= Self.quickRetryMs.count || why(error) != .transient { throw error }
                let wait = Self.quickRetryMs[tried]
                tried += 1
                log("could not download \(videoId) (\(error.localizedDescription)), trying again in \(wait)ms")
                try await pause(wait)
            }
        }
    }

    func drain(waiting: Bool) async throws -> Result {
        let state = waiting ? LibraryStore.waiting : LibraryStore.queued
        // A song that failed now is not taken again in this run; its next try is for the next run
        var failedNow: Set<String> = []
        var done = 0
        var retryLater = false
        // Songs that were put to failed at once without being tried (no room on the phone): they count as failed in the run
        var setAside = 0
        progress = .idle
        do {
            songs: while let videoId = try await store.nextDownload(state, skip: failedNow) {
                progress = Batch(active: videoId, done: done,
                                 total: done + failedNow.count + setAside + (try await store.pendingDownloads(state, skip: failedNow)),
                                 failed: failedNow.count + setAside)
                do {
                    try await store.finishDownload(videoId, bytes: try await fetchPatiently(videoId))
                    done += 1
                } catch is CancellationError {
                    throw CancellationError() // stopped: the song stays on the list as it was
                } catch {
                    log("could not download \(videoId): \(error.localizedDescription)")
                    switch why(error) {
                    case .unavailable:
                        // A video YouTube will not give out is the same on every try: it says so now instead of after three
                        failedNow.insert(videoId)
                        try await store.markUnavailable(videoId)
                    case .offline:
                        // The run stops where it is: every other song would meet the same, and a try used up on each would
                        // leave them all failed for want of a network that comes back. They stay on the list, and the job is
                        // asked to run again
                        log("no internet: the run stops, and no try of the songs is used up")
                        retryLater = true
                        break songs
                    case .noSpace:
                        // No room: this song and the ones waiting are put to failed at once, so that the person sees it and,
                        // once there is room, tries them again with one button, instead of the job going on and on
                        log("no room on the phone: the run stops, and the songs on the list are set aside")
                        failedNow.insert(videoId)
                        try await store.failNow(videoId)
                        setAside += try await store.failAllWaiting(state)
                        break songs
                    case .transient:
                        failedNow.insert(videoId)
                        if try await !store.failDownload(videoId) { retryLater = true }
                    }
                }
            }
        } catch {
            progress = .idle // a run that was cut short is not a finished one: nothing to announce
            throw error
        }
        let failed = failedNow.count + setAside
        let taken = done + failed
        progress = taken == 0 ? .idle : Batch(active: nil, done: done, total: taken, failed: failed)
        return Result(done: done, retryLater: retryLater)
    }
}
