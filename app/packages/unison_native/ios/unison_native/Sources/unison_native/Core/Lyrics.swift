import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One line of a song, sung from [ms] on.
struct LyricLine: Equatable {
    let ms: Int64
    let text: String
}

/// The words of a song. [lines] carry times when the lyrics run along with the music; otherwise only [plain] is known.
struct Lyrics: Equatable {
    let lines: [LyricLine]
    let plain: String?

    var synced: Bool { !lines.isEmpty }
}

/// Reads the `[mm:ss.xx] words` format that lyrics with times come in.
enum Lrc {
    private static let tag = try! NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]")

    /// Lines in time order. A line with several times gives one line for each; tags like `[ar:Name]` are skipped.
    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            let tags = tag.matches(in: line, range: range)
            let words = tag.stringByReplacingMatches(in: line, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
            for match in tags {
                func group(_ index: Int) -> String {
                    Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
                }
                let minutes = Int64(group(1)) ?? 0
                let seconds = Int64(group(2)) ?? 0
                // ".5" is half a second and ".500" too
                var fraction = group(3)
                while fraction.count < 3 { fraction += "0" }
                lines.append(LyricLine(ms: (minutes * 60 + seconds) * 1000 + (Int64(fraction.prefix(3)) ?? 0), text: words))
            }
        }
        // Stable: equal times keep the order they were written in
        return lines.enumerated().sorted { ($0.element.ms, $0.offset) < ($1.element.ms, $1.offset) }.map(\.element)
    }
}

/// Gets one address and gives its text, or nil when there is nothing there (404).
typealias LyricsFetch = (_ url: String) async throws -> String?

/// Lyrics that run along with the music, from [LRCLIB](https://lrclib.net): a free service kept by volunteers that
/// needs no key. It is told the title, artist and length of the song, nothing else.
struct LyricsClient {
    /// Lyrics of a song this much longer or shorter are probably of another recording.
    static let maxLengthGapSec = 5.0

    private let fetch: LyricsFetch

    init(fetch: @escaping LyricsFetch) {
        self.fetch = fetch
    }

    init(http: HTTPClient = URLSessionHTTP()) {
        self.init { url in
            guard let address = URL(string: url) else { throw URLError(.badURL) }
            var request = URLRequest(url: address)
            request.setValue("Unison (private group listening app)", forHTTPHeaderField: "User-Agent")
            let reply = try await http.send(request)
            if reply.status == 404 { return nil }
            guard (200..<300).contains(reply.status) else { throw HTTPFailure(status: reply.status, service: "LRCLIB") }
            return reply.text
        }
    }

    /// The lyrics of the song, or nil when LRCLIB has none. The exact name is tried first, then the name without tags.
    func find(title: String, artist: String, durationSec: Int64) async throws -> Lyrics? {
        var names: [(String, String)] = [(title, artist)]
        let cleaned = (SongNames.title(title, artist: artist), SongNames.artist(artist))
        if cleaned != names[0] { names.append(cleaned) }
        for (t, a) in names {
            if let found = try await exact(t, a, durationSec) { return found }
        }
        let (t, a) = names.last!
        return try await closest(t, a, durationSec)
    }

    private func exact(_ title: String, _ artist: String, _ durationSec: Int64) async throws -> Lyrics? {
        let query = [("track_name", title), ("artist_name", artist), ("duration", durationSec > 0 ? String(durationSec) : nil)]
        guard let body = try await fetch(url("get", query)) else { return nil }
        guard let json = JSON.parse(body), json.object != nil else { return nil }
        return lyricsOf(json)
    }

    /// With no exact match, the song of about the same length that has the most to show.
    private func closest(_ title: String, _ artist: String, _ durationSec: Int64) async throws -> Lyrics? {
        guard let body = try await fetch(url("search", [("track_name", title), ("artist_name", artist)])) else { return nil }
        let candidates = (JSON.parse(body)?.array ?? []).filter { $0.object != nil }
        let near = candidates.filter { durationSec <= 0 || abs(($0.at("duration").double ?? 0) - Double(durationSec)) <= Self.maxLengthGapSec }
        let found = near.compactMap(lyricsOf)
        return found.first { $0.synced } ?? found.first
    }

    private func lyricsOf(_ item: JSON) -> Lyrics? {
        if item.at("instrumental").bool == true { return nil }
        let lines = item.at("syncedLyrics").string.map(Lrc.parse) ?? []
        let plain = item.at("plainLyrics").string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return lines.isEmpty && plain == nil ? nil : Lyrics(lines: lines, plain: plain)
    }

    private func url(_ path: String, _ query: [(String, String?)]) -> String {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        return components.string ?? ""
    }
}

/// Titles and artists as people type them on YouTube, brought closer to what a song is called.
enum SongNames {
    /// Words that describe a recording or a video of it, not the song: "(Official Video)", "[Lyrics]", "(Remastered 2009)".
    private static let noise = try! NSRegularExpression(
        pattern: "official|video|audio|lyric|visuali[sz]er|\\bm/?v\\b|\\bhd\\b|\\bhq\\b|\\b4k\\b|remaster|\\bclip\\b|full (song|album)|\\bfeat\\b|\\bft\\b",
        options: [.caseInsensitive]
    )
    private static let brackets = try! NSRegularExpression(pattern: "\\s*[(\\[][^)\\]]*[)\\]]")
    private static let artistSplit = try! NSRegularExpression(
        pattern: "\\s*(?:,|&|\\bx\\b|\\bfeat\\.?|\\bft\\.?|\\bvà\\b|\\band\\b)\\s*", options: [.caseInsensitive])
    private static let channelSuffix = try! NSRegularExpression(
        pattern: "\\s*(?:-\\s*topic|vevo|official(?:\\s+channel)?)$", options: [.caseInsensitive])

    /// The title without bracketed tags that only describe the recording. "Remix", "Live" and "Acoustic" stay: they
    /// are other recordings. With [artist], a leading "Artist - " is dropped too.
    static func title(_ raw: String, artist: String? = nil) -> String {
        var text = replace(brackets, in: raw) { piece in
            noise.firstMatch(in: piece, range: NSRange(piece.startIndex..., in: piece)) != nil ? "" : piece
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dash = text.range(of: " - "), dash.lowerBound > text.startIndex, let artist {
            let main = Self.artist(artist)
            let lead = String(text[..<dash.lowerBound])
            if !main.isEmpty && lead.range(of: main, options: .caseInsensitive) != nil {
                text = String(text[dash.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    /// The first artist of a credit like "A, B & C", without "- Topic", "VEVO" or "Official".
    static func artist(_ raw: String) -> String {
        let credit = replace(channelSuffix, in: raw.trimmingCharacters(in: .whitespacesAndNewlines)) { _ in "" }
        let range = NSRange(credit.startIndex..., in: credit)
        var first = credit
        if let split = artistSplit.firstMatch(in: credit, range: range), let cut = Range(split.range, in: credit) {
            first = String(credit[..<cut.lowerBound])
        }
        return replace(channelSuffix, in: first) { _ in "" }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// [regex] replaced in [text], each match by what [transform] makes of it.
    private static func replace(_ regex: NSRegularExpression, in text: String, _ transform: (String) -> String) -> String {
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}

/// What was kept for a song: its lyrics, or the knowledge that there are none.
enum KeptLyrics: Equatable {
    case found(Lyrics)
    /// Looked for [checkedAt] and not found; asking again is worth it after a while.
    case missing(checkedAt: Int64)
}

/// Lyrics kept in files, one per song, so that a song played again has its words at once and offline. Only the
/// newest [maxEntries] files stay.
final class LyricsStore {
    private let dir: URL
    private let maxEntries: Int

    init(dir: URL, maxEntries: Int = 400) {
        self.dir = dir
        self.maxEntries = maxEntries
    }

    func get(_ videoId: String) -> KeptLyrics? {
        let file = fileURL(videoId)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let json = JSON.parse(data: data), json.object != nil else {
            // A file cut short by a crash is as good as none
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        if let missing = json.at("missing").int64 { return .missing(checkedAt: missing) }
        let lines = json.at("lines").array.map { LyricLine(ms: $0[0].int64 ?? 0, text: $0[1].string ?? "") }
        return .found(Lyrics(lines: lines, plain: json.at("plain").string))
    }

    func putFound(_ videoId: String, _ lyrics: Lyrics) {
        var object: [String: Any] = ["lines": lyrics.lines.map { [$0.ms, $0.text] as [Any] }]
        if let plain = lyrics.plain { object["plain"] = plain }
        write(videoId, object)
    }

    func putMissing(_ videoId: String, checkedAt: Int64) {
        write(videoId, ["missing": checkedAt])
    }

    private func write(_ videoId: String, _ object: [String: Any]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: fileURL(videoId), options: .atomic)
        trim()
    }

    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        let json = files.filter { $0.pathExtension == "json" }
        let dated = json.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(maxEntries) { try? FileManager.default.removeItem(at: file) }
    }

    // A video id has only letters, digits, - and _, but nothing is written with a name that came from outside unchecked
    private func fileURL(_ videoId: String) -> URL {
        let name = String(videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return dir.appendingPathComponent(name + ".json")
    }
}

/// What the full player shows about a song. Every answer is kept for a while, so going back and forth between songs,
/// or opening the same page twice, does not ask again; lyrics are kept in files.
actor MusicFeed {
    /// A song without lyrics is looked up again after this long.
    static let missingMs: Int64 = 7 * 24 * 60 * 60 * 1000

    /// The home page of YouTube Music changes by the hour at most.
    static let trendingMs: Int64 = 6 * 60 * 60 * 1000

    private let music: MusicSource
    private let lyricsClient: LyricsClient
    private let lyricsStore: LyricsStore
    private let now: @Sendable () -> Int64

    private var nextKept = Recent<String, WatchNext>()
    private var relatedKept = Recent<String, Related>()
    private var artistsKept = Recent<String, ArtistPage>()
    private var collectionsKept = Recent<String, CollectionPage>()
    private var searchesKept = Recent<String, SearchPage>()
    private var trendingKept: (language: String, at: Int64, shelves: [MusicShelf])?
    private let lyricsLock = AsyncMutex()

    init(music: MusicSource, lyricsClient: LyricsClient, lyricsStore: LyricsStore,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.music = music
        self.lyricsClient = lyricsClient
        self.lyricsStore = lyricsStore
        self.now = now
    }

    /// The radio of the song, with where its lyrics and related page are.
    func watchNext(_ videoId: String) async throws -> WatchNext {
        if let kept = nextKept[videoId] { return kept }
        let found = try await music.watchNext(videoId)
        nextKept[videoId] = found
        return found
    }

    func related(_ videoId: String) async throws -> Related? {
        guard let page = try await watchNext(videoId).relatedId else { return nil }
        if let kept = relatedKept[page] { return kept }
        let found = try await music.related(page)
        relatedKept[page] = found
        return found
    }

    func artist(_ artistId: String) async throws -> ArtistPage {
        if let kept = artistsKept[artistId] { return kept }
        let found = try await music.artist(artistId)
        artistsKept[artistId] = found
        return found
    }

    /// An album or a playlist, with its first songs.
    func collection(_ id: String) async throws -> CollectionPage {
        if let kept = collectionsKept[id] { return kept }
        let found = try await music.collection(id)
        collectionsKept[id] = found
        return found
    }

    /// The next songs of a long playlist; asked for as the person scrolls, so not kept.
    func more(_ token: String) async throws -> Continuation {
        try await music.more(token)
    }

    /// What YouTube Music shows everybody, kept for [trendingMs] (and not shown in another language than it was asked in).
    func trending(_ language: String = "en") async throws -> [MusicShelf] {
        if let kept = trendingKept, kept.language == language, now() - kept.at < Self.trendingMs { return kept.shelves }
        let shelves = try await music.trending(language: language)
        trendingKept = (language, now(), shelves)
        return shelves
    }

    /// Everything matching [query], or only what [params] (a filter of the page) keeps; kept, so going back to it is free.
    func searchPage(_ query: String, params: String?) async throws -> SearchPage {
        let key = (params ?? "") + "\n" + query
        if let kept = searchesKept[key] { return kept }
        let found = try await music.searchPage(query, params: params)
        searchesKept[key] = found
        return found
    }

    /// The results after those of [searchPage]; asked for as the person scrolls, so not kept.
    func searchMore(_ token: String) async throws -> SearchPage {
        try await music.searchMore(token)
    }

    /// Songs matching [query], as audio releases or as videos.
    func search(_ query: String, songs: Bool) async throws -> [MusicTrack] {
        songs ? try await music.searchSongs(query) : try await music.searchVideos(query)
    }

    /// The songs of a YouTube playlist and its title, as YouTube Music lists them.
    func playlist(_ playlistId: String) async throws -> (title: String?, tracks: [MusicTrack]) {
        try await music.playlist(playlistId)
    }

    /// The lyrics of a song: lyrics with times when LRCLIB has them, else the plain words YouTube Music has, else nil.
    /// A failed attempt (no network) is not kept, so the next look tries again.
    func lyrics(videoId: String, title: String, artist: String, durationSec: Int64) async throws -> Lyrics? {
        try await lyricsLock.withLock { try await self.findLyrics(videoId, title, artist, durationSec) }
    }

    private func findLyrics(_ videoId: String, _ title: String, _ artist: String, _ durationSec: Int64) async throws -> Lyrics? {
        switch lyricsStore.get(videoId) {
        case let .found(lyrics)?:
            return lyrics
        case let .missing(checkedAt)?:
            if now() - checkedAt < Self.missingMs { return nil }
        case nil:
            break
        }
        let timed = try await lyricsClient.find(title: title, artist: artist, durationSec: durationSec)
        var found = timed
        if timed?.synced != true {
            found = try await plainFromYoutube(videoId) ?? timed
        }
        if let found { lyricsStore.putFound(videoId, found) } else { lyricsStore.putMissing(videoId, checkedAt: now()) }
        return found
    }

    private func plainFromYoutube(_ videoId: String) async throws -> Lyrics? {
        guard let page = try await watchNext(videoId).lyricsId else { return nil }
        return try await music.lyrics(page).map { Lyrics(lines: [], plain: $0) }
    }

    /// The last few answers, oldest let go first.
    private struct Recent<K: Hashable, V> {
        private let size = 24
        private var values: [K: V] = [:]
        private var order: [K] = []

        subscript(key: K) -> V? {
            mutating get {
                guard let value = values[key] else { return nil }
                order.removeAll { $0 == key }
                order.append(key)
                return value
            }
            set {
                guard let newValue else { return }
                values[key] = newValue
                order.removeAll { $0 == key }
                order.append(key)
                while order.count > size { values[order.removeFirst()] = nil }
            }
        }
    }
}
