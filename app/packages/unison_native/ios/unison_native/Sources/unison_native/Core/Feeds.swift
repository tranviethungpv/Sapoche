import Foundation

/// What to offer to play. YouTube lists related songs beside any song, so suggestions come from a few songs the person
/// loves most (the seeds, chosen by [Taste] from what they heard, liked and left after a few seconds). The lists are
/// kept for [freshMs], so opening the app shows them at once, even offline, and the network is only used to renew them.
actor SuggestionFeed {
    static let forYouCount = 30
    static let discoverCount = 20
    static let contextCount = 20
    static let seedCount = 5
    static let freshMs: Int64 = 12 * 60 * 60 * 1000
    static let song = "song"
    static let artist = "artist"
    private static let recentMs: Int64 = 7 * 24 * 60 * 60 * 1000

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
        let heard = try await store.listens().map { Stamped(track: $0.track, at: $0.at) }
        let liked = try await store.liked().map { Stamped(track: $0.track, at: $0.at) }
        let skipped = try await store.skipped().map { Stamped(track: $0.track, at: $0.at) }
        return Taste(heard: heard, liked: liked, skipped: skipped, now: now())
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
        let taste = try await loadTaste()
        let block = try await blocklist()
        let heard = try await store.heardSince(now() - Self.recentMs)
        return Suggestions.mix([try await radioOf(videoId)], exclude: exclude.union([videoId]).union(heard), limit: count) {
            Suggestions.welcome($0, taste: taste, block: block)
        }
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

    private let store: LibraryStore
    /// Brings the whole song onto the phone and gives back its size in bytes; throws when it cannot.
    private let fetch: @Sendable (String) async throws -> Int64
    private let log: @Sendable (String) -> Void

    init(store: LibraryStore, fetch: @escaping @Sendable (String) async throws -> Int64, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.fetch = fetch
        self.log = log
    }

    func drain(waiting: Bool) async throws -> Result {
        let state = waiting ? LibraryStore.waiting : LibraryStore.queued
        // A song that failed now is not taken again in this run; its next try is for the next run
        var failedNow: Set<String> = []
        var done = 0
        var retryLater = false
        while let videoId = try await store.nextDownload(state, skip: failedNow) {
            do {
                try await store.finishDownload(videoId, bytes: try await fetch(videoId))
                done += 1
            } catch is CancellationError {
                throw CancellationError() // stopped: the song stays on the list as it was
            } catch {
                log("could not download \(videoId): \(error.localizedDescription)")
                failedNow.insert(videoId)
                if try await !store.failDownload(videoId) { retryLater = true }
            }
        }
        return Result(done: done, retryLater: retryLater)
    }
}
