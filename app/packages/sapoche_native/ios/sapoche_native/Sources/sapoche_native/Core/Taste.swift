import Foundation

/// A song with the moment something happened to it: it was heard, liked or left after a few seconds. [weight] is how
/// much it counts (see `ListenSource.weight`).
struct Stamped: Equatable {
    let track: TrackRef
    let at: Int64
    var weight = 1.0
}

/// How much an artist is loved: [key] is `Taste.artistKey`, [label] the name as it is written.
struct ArtistScore: Equatable {
    let key: String
    let label: String
    let score: Double
}

/// Songs and artists the person asked not to be offered, by video id and by [Taste.artistKey].
struct Blocklist {
    var songs: Set<String> = []
    var artists: Set<String> = []

    func allows(_ track: TrackRef) -> Bool {
        !songs.contains(track.videoId) && !artists.contains(Taste.artistKey(track.artist))
    }
}

/// What the listening says about a person's taste: how much each song and each artist is loved, from what was heard
/// (a point each), liked (more) and left after a few seconds (less than nothing), all counting for less as they get
/// older. Nothing leaves the phone and nothing needs the network; it only reads what the library keeps.
struct Taste {
    static let heardWeight = 1.0
    static let likedWeight = 2.5
    static let skippedWeight = -1.2
    static let playHalfLifeMs: Int64 = 21 * 24 * 60 * 60 * 1000
    static let likeHalfLifeMs: Int64 = 90 * 24 * 60 * 60 * 1000
    static let known = 0.5
    static let disliked = -2.0
    static let minSeed = 0.5
    static let contextWindowMs: Int64 = 60 * 24 * 60 * 60 * 1000
    static let minContext = 5
    static let maxArtists = 60
    static let maxSongs = 800

    /// The parts of a day, for the mix that suits the time: morning, afternoon, evening and night.
    static let buckets = ["morning", "afternoon", "evening", "night"]

    private let heard: [Stamped]
    private let quietSongs: Set<String>
    private let quietArtists: Set<String>
    private let now: Int64
    private let hourOf: (Int64) -> Int
    private var songs: [String: Double] = [:]
    private var artists: [String: Double] = [:]
    private var tracks: [String: TrackRef] = [:]
    private var labels: [String: String] = [:]

    /// [quietSongs] are songs the person asked not to count: whatever happened to them is left out. [quietArtists] are artists
    /// (by `artistKey`) the person wants fewer suggestions of: their score is nothing, and they are never a seed or offered
    /// to a room.
    init(heard: [Stamped], liked: [Stamped], skipped: [Stamped], now: Int64, hourOf: ((Int64) -> Int)? = nil,
         quietSongs: Set<String> = [], quietArtists: Set<String> = []) {
        self.heard = heard
        self.quietSongs = quietSongs
        self.quietArtists = quietArtists
        self.now = now
        self.hourOf = hourOf ?? Taste.localHour
        add(heard, weight: Self.heardWeight, halfLifeMs: Self.playHalfLifeMs)
        add(liked, weight: Self.likedWeight, halfLifeMs: Self.likeHalfLifeMs)
        add(skipped, weight: Self.skippedWeight, halfLifeMs: Self.playHalfLifeMs)
        for key in quietArtists where artists[key] != nil { artists[key] = 0 }
    }

    /// The person asked for fewer suggestions of this artist.
    func isQuiet(_ artist: String) -> Bool { quietArtists.contains(Taste.artistKey(artist)) }

    private mutating func add(_ list: [Stamped], weight: Double, halfLifeMs: Int64) {
        for stamped in list {
            if quietSongs.contains(stamped.track.videoId) { continue }
            let value = weight * stamped.weight * Taste.decay(now - stamped.at, halfLifeMs)
            songs[stamped.track.videoId, default: 0] += value
            artists[Taste.artistKey(stamped.track.artist), default: 0] += value
            if tracks[stamped.track.videoId] == nil { tracks[stamped.track.videoId] = stamped.track }
            let key = Taste.artistKey(stamped.track.artist)
            if labels[key] == nil { labels[key] = Taste.artistLabel(stamped.track.artist) }
        }
    }

    /// How much the song is loved: below nothing when it was left more than it was heard; 0 for a song never met.
    func songScore(_ videoId: String) -> Double { songs[videoId] ?? 0 }

    /// How much the artist is loved, as `songScore` is for a song.
    func artistScore(_ artist: String) -> Double { artists[Taste.artistKey(artist)] ?? 0 }

    /// The most an artist is loved; 0 or less when no artist is loved.
    var strongestArtist: Double { artists.values.max() ?? 0 }

    /// The [limit] artists with the highest score, the highest first.
    func artistScores(limit: Int = Taste.maxArtists) -> [ArtistScore] {
        artists.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { ArtistScore(key: $0.key, label: labels[$0.key] ?? "", score: $0.value) }
    }

    /// The scores of the [limit] songs that count most, either way: what is loved and what is left again and again.
    func songScores(limit: Int = Taste.maxSongs) -> [String: Double] {
        let top = songs.sorted { abs($0.value) != abs($1.value) ? abs($0.value) > abs($1.value) : $0.key < $1.key }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
    }

    /// The artist has been listened to, or liked, enough to be known.
    func knows(_ artist: String) -> Bool {
        (artists[Taste.artistKey(artist)] ?? 0) >= Self.known
    }

    /// The artist's songs were left lately more than they were heard.
    func dislikes(_ artist: String) -> Bool {
        (artists[Taste.artistKey(artist)] ?? 0) <= Self.disliked
    }

    /// The songs suggestions are built from, up to [count]: the best loved, one per artist where there are enough
    /// artists, so the mix is not all one voice. A song of an artist that is disliked or blocked is never one.
    func seeds(_ count: Int, block: Blocklist = Blocklist()) -> [String] { offer(count, block: block).map(\.videoId) }

    /// The songs the person offers a room's autoplay to start from: `seeds` as they are (songs of files, and of artists
    /// disliked or blocked, are never one).
    func offer(_ count: Int, block: Blocklist = Blocklist()) -> [TrackRef] {
        var scored: [(track: TrackRef, score: Double)] = []
        // A song from a file on this phone has no radio to ask for: it tells what is liked, but is never a seed
        for (id, score) in songs where score >= Self.minSeed && !LocalMusic.isLocal(id) {
            guard let track = tracks[id], block.allows(track), !dislikes(track.artist), !isQuiet(track.artist) else { continue }
            scored.append((track, score))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.track.videoId < $1.track.videoId }
        var picked: [TrackRef] = []
        var perArtist: [String: Int] = [:]
        for cap in 1...2 {
            for entry in scored {
                if picked.count >= count { break }
                let key = Taste.artistKey(entry.track.artist)
                if picked.contains(where: { $0.videoId == entry.track.videoId }) || (perArtist[key] ?? 0) >= cap { continue }
                picked.append(entry.track)
                perArtist[key, default: 0] += 1
            }
        }
        return picked
    }

    /// The songs the person plays at this time of day ([bucket], see [bucketOf]), most played first, up to [count], one
    /// per artist; empty until enough was heard at that time for it to mean something.
    func contextSeeds(_ bucket: String, block: Blocklist = Blocklist(), count: Int = 2) -> [TrackRef] {
        let since = now - Self.contextWindowMs
        let inBucket = heard.filter { $0.at >= since && !quietSongs.contains($0.track.videoId) && Taste.bucketOf(hourOf($0.at)) == bucket }
        if inBucket.count < Self.minContext { return [] }
        var plays: [String: Double] = [:]
        var seen: [String: TrackRef] = [:]
        for stamped in inBucket {
            plays[stamped.track.videoId, default: 0] += Taste.decay(now - stamped.at, Self.playHalfLifeMs)
            if seen[stamped.track.videoId] == nil { seen[stamped.track.videoId] = stamped.track }
        }
        let order = plays.keys.sorted { plays[$0]! != plays[$1]! ? plays[$0]! > plays[$1]! : $0 < $1 }
        var picked: [TrackRef] = []
        var taken = Set<String>()
        for id in order {
            if picked.count >= count { break }
            guard let track = seen[id] else { continue }
            if LocalMusic.isLocal(id) || !block.allows(track) || isQuiet(track.artist) || (songs[id] ?? 0) <= 0 || !taken.insert(Taste.artistKey(track.artist)).inserted { continue }
            picked.append(track)
        }
        return picked
    }

    static func bucketOf(_ hour: Int) -> String {
        switch hour {
        case 5...10: return "morning"
        case 11...16: return "afternoon"
        case 17...21: return "evening"
        default: return "night"
        }
    }

    private static func decay(_ ageMs: Int64, _ halfLifeMs: Int64) -> Double {
        pow(0.5, Double(max(ageMs, 0)) / Double(halfLifeMs))
    }

    private static func localHour(_ at: Int64) -> Int {
        Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(at) / 1000))
    }

    private static let channelSuffix = try! NSRegularExpression(pattern: "\\s*(?:-\\s*topic|vevo|official(?:\\s+channel)?)$", options: [.caseInsensitive])
    private static let artistSplit = try! NSRegularExpression(pattern: "\\s*(?:,|&|\\bx\\b|\\bfeat\\.?|\\bft\\.?|\\bvà\\b|\\band\\b)\\s*", options: [.caseInsensitive])
    private static let punctuation = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N}]+", options: [])

    private static func withoutSuffix(_ text: String) -> String {
        channelSuffix.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// The first artist of a credit like "A, B & C" as it is written, without "- Topic", "VEVO" or "Official".
    static func artistLabel(_ credit: String) -> String {
        let text = withoutSuffix(credit.trimmingCharacters(in: .whitespacesAndNewlines))
        var first = text
        if let match = artistSplit.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            first = String(text[..<range.lowerBound])
        }
        return withoutSuffix(first).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What tells one artist from another: the first artist of a credit in plain lower-case letters (as the UI does).
    static func artistKey(_ credit: String) -> String {
        let label = artistLabel(credit).lowercased()
        return punctuation.stringByReplacingMatches(in: label, options: [], range: NSRange(label.startIndex..., in: label), withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
