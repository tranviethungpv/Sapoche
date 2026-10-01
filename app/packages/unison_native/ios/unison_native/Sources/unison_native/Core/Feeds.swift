import Foundation

/// What to offer to play. YouTube lists related songs beside any song, so suggestions come from a few songs the
/// person likes or plays a lot (the seeds). The lists are kept for [freshMs], so opening the app shows them at once,
/// even offline, and the network is only used to renew them.
actor SuggestionFeed {
    static let forYouCount = 30
    static let freshMs: Int64 = 12 * 60 * 60 * 1000
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

    /// Songs to offer, from what is kept; nothing until there are seeds and their lists were fetched once.
    func forYou(limit: Int = SuggestionFeed.forYouCount) async throws -> [TrackRef] {
        let seeds = try await store.suggestionSeeds(now: now())
        var lists: [[TrackRef]] = []
        for seed in seeds {
            if let kept = try await store.cachedSuggestions(seed) { lists.append(kept.tracks) }
        }
        return Suggestions.mix(lists, exclude: try await known(seeds), limit: limit)
    }

    /// Fetches again the lists of the seeds whose list is missing or older than [freshMs], or all of them with [force].
    /// One failed seed does not stop the others; what was kept for it stays. Returns whether anything changed.
    func renew(force: Bool) async throws -> Bool {
        try await renewing.withLock { try await self.renewSeeds(force: force) }
    }

    private func renewSeeds(force: Bool) async throws -> Bool {
        let seeds = try await store.suggestionSeeds(now: now())
        var changed = false
        for seed in seeds {
            let kept = try await store.cachedSuggestions(seed)
            if !force, let kept, now() - kept.fetchedAt < Self.freshMs { continue }
            do {
                let songs = try await radioOf(seed).filter(Suggestions.isSong)
                try await store.putSuggestions(seed, songs, at: now())
                changed = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("could not fetch suggestions for \(seed): \(error.localizedDescription)")
            }
        }
        try await store.keepSuggestionsFor(seeds)
        return changed
    }

    /// The songs kept for each seed, for the screens that say "because you listened to".
    func seedLists() async throws -> [(seed: String, tracks: [TrackRef])] {
        var lists: [(seed: String, tracks: [TrackRef])] = []
        for seed in try await store.suggestionSeeds(now: now()) {
            if let kept = try await store.cachedSuggestions(seed) { lists.append((seed, kept.tracks)) }
        }
        return lists
    }

    /// Up to [count] songs to carry on with after [videoId], other than [exclude] and what was heard lately: the radio
    /// YouTube Music makes of the song, or what YouTube lists beside it when that cannot be had. Needs the network.
    func after(_ videoId: String, exclude: Set<String>, count: Int) async throws -> [TrackRef] {
        let heard = try await store.heardSince(now() - Self.recentMs)
        return Suggestions.mix([try await radioOf(videoId)], exclude: exclude.union([videoId]).union(heard), limit: count)
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
