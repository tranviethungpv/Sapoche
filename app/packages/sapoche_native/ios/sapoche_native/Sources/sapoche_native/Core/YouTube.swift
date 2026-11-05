import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal track metadata, enough to display a result and put it on the queue.
struct TrackInfo: Equatable {
    let videoId: String
    let title: String
    let artist: String
    let thumbUrl: String?
    let durationSec: Int64

    var ref: TrackRef {
        TrackRef(videoId: videoId, title: title, artist: artist, thumb: thumbUrl, durMs: durationSec * 1000)
    }
}

/// A playlist found by search, not yet opened.
struct PlaylistRef: Equatable {
    let id: String
    let title: String
    let uploader: String
    let thumbUrl: String?
    let songCount: Int64
}

/// A playlist's songs in order, without the unavailable ones.
struct Playlist: Equatable {
    let title: String
    let tracks: [TrackInfo]
}

/// Where the parts of a DASH file are: the header ends at [initEnd], and the index of its pieces (a `sidx` box) is
/// at [indexStart]...[indexEnd]. YouTube gives these with each stream.
struct DashRanges: Equatable {
    let initEnd: Int64
    let indexStart: Int64
    let indexEnd: Int64

    /// The ranges of a stream in a `player` answer, or nil when it has none that make sense.
    static func of(_ format: JSON) -> DashRanges? {
        guard let initStart = format.at("initRange", "start").int64, let initEnd = format.at("initRange", "end").int64,
              let indexStart = format.at("indexRange", "start").int64, let indexEnd = format.at("indexRange", "end").int64,
              initStart == 0, initEnd > 0, indexStart > initEnd, indexEnd > indexStart else { return nil }
        return DashRanges(initEnd: initEnd, indexStart: indexStart, indexEnd: indexEnd)
    }
}

/// A resolved audio stream, with details used to judge quality.
struct AudioSource: Equatable {
    let url: String
    let mimeType: String
    let bitrateKbps: Int
    let contentLength: Int64
    let itag: Int
    var index: DashRanges? = nil
    /// How many dB the song is above YouTube's reference level (negative when below), when the answer says.
    var loudnessDb: Double? = nil
}

/// A picture-only stream, played together with an audio stream when the picture is wanted.
struct VideoSource: Equatable {
    let url: String
    let height: Int
    /// Codec as YouTube reports it, e.g. "avc1.4d401f".
    let codec: String
    let bitrateKbps: Int
    let itag: Int
    var contentLength: Int64 = -1
    var index: DashRanges? = nil
}

/// How much sound a song is fetched in, from the least data to the most YouTube offers. [level] is what the settings keep
/// (the same numbers as on Android), [maxKbps] the most a step may take. A video offers a few streams, so a step takes the
/// best stream within its limit and, when the video has none that low, the smallest one it has. An iPhone plays only AAC,
/// so it often has fewer streams to choose from than other phones.
enum AudioQuality: Int, CaseIterable {
    case low = 0, normal, high, max

    private var maxKbps: Int {
        switch self {
        case .low: return 0
        case .normal: return 80
        case .high: return 130
        case .max: return .max
        }
    }

    /// The step for a saved level; anything unknown is the best, which is what the app did before there was a choice.
    init(level: Int) {
        self = Self(rawValue: level) ?? .max
    }

    /// The stream of [sources] this step stands for; nil when there are none.
    func choose(_ sources: [AudioSource]) -> AudioSource? {
        switch self {
        case .max: return sources.max { $0.bitrateKbps < $1.bitrateKbps }
        case .low: return sources.min { $0.bitrateKbps < $1.bitrateKbps }
        default:
            return sources.filter { $0.bitrateKbps <= maxKbps }.max { $0.bitrateKbps < $1.bitrateKbps }
                ?? sources.min { $0.bitrateKbps < $1.bitrateKbps }
        }
    }
}

/// Chooses which video-only stream to play beside the audio.
enum VideoPicker {
    /// The tallest stream that fits within [maxHeight]. When nothing fits (the video has only larger streams) the
    /// smallest available one is used rather than none at all. Only H.264 is on offer: it is what an iPhone plays.
    static func pick(_ sources: [VideoSource], maxHeight: Int) -> VideoSource? {
        let playable = sources.filter { $0.codec.hasPrefix("avc1") }
        guard !playable.isEmpty else { return nil }
        let fitting = playable.filter { $0.height <= maxHeight }
        guard let tallest = fitting.map(\.height).max() else { return playable.min { $0.height < $1.height } }
        return fitting.filter { $0.height == tallest }.max { $0.bitrateKbps < $1.bitrateKbps }
    }
}

struct Resolved: Equatable {
    let track: TrackInfo
    let best: AudioSource
    let all: [AudioSource]
    /// Picture-only streams found beside the audio; empty when the video cannot be played.
    var videos: [VideoSource] = []
    /// What the addresses expect to be fetched as: YouTube checks that the caller is the app they were made for.
    var userAgent = ""
}

/// Swappable stream source: this device, a home host, etc. The rest of the app only knows this interface.
protocol StreamResolver {
    /// Up to [limit] videos matching [query], over as many pages as it takes; with [songsOnly] only what YouTube Music lists as songs.
    func search(_ query: String, limit: Int, songsOnly: Bool) async throws -> [TrackInfo]
    func resolve(_ videoId: String) async throws -> Resolved

    /// Playlists matching [query].
    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistRef]

    /// The first [limit] playable songs of the playlist with the given id.
    func playlist(_ playlistId: String, limit: Int) async throws -> Playlist

    /// Videos YouTube lists beside the one with [videoId], in its order; live streams and lengthless ones left out.
    func related(_ videoId: String, limit: Int) async throws -> [TrackInfo]

    /// What YouTube would complete [query] to while it is being typed.
    func suggest(_ query: String) async throws -> [String]
}

struct ResolveFailure: Error, LocalizedError {
    let message: String
    /// YouTube said the video does not play (removed, private, blocked here, live), as opposed to failing to answer.
    var unplayable = false

    var errorDescription: String? { message }
}

/// Picks video and playlist ids out of whatever the user pasted.
enum YoutubeLinks {
    private static let videoLinks = [
        "youtube\\.com/watch\\?(?:.*&)?v=([A-Za-z0-9_-]{11})",
        "youtu\\.be/([A-Za-z0-9_-]{11})",
        "youtube\\.com/(?:shorts|embed|live)/([A-Za-z0-9_-]{11})",
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let playlistLink = try! NSRegularExpression(pattern: "youtube\\.com/playlist\\?(?:.*&)?list=([A-Za-z0-9_-]{10,})")
    private static let bareId = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{11}$")

    /// The playlist id of a link to a playlist page. A video opened inside a playlist is just that video.
    static func playlistId(_ text: String) -> String? { firstGroup(playlistLink, in: text) }

    /// The video id of a video link, or of a bare id. Nil for anything else, including ordinary search words.
    static func videoId(_ text: String) -> String? {
        for pattern in videoLinks {
            if let id = firstGroup(pattern, in: text) { return id }
        }
        // A bare id must not be an ordinary 11 letter word from a search: real ids nearly always have a digit, _ or -
        let whole = NSRange(text.startIndex..., in: text)
        guard bareId.firstMatch(in: text, range: whole) != nil, text.contains(where: { $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return text
    }

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// How this device introduces itself to YouTube. The visionOS app of YouTube is what gives audio streams that
/// need no sign-in and no proof-of-origin token (the iPhone app's streams break with 403 after their first 8 KB). If
/// YouTube retires it, this is the one place to change; `androidVR` is what is asked when it has turned us down twice.
struct InnertubeClient {
    let name: String
    let id: Int
    let version: String
    let model: String
    let osName: String
    let osVersion: String
    let userAgent: String
    var make = "Apple"
    var androidSdk: Int?

    static let visionOS = InnertubeClient(
        name: "VISIONOS", id: 101, version: "1.02", model: "RealityDevice14,1", osName: "visionOS", osVersion: "25.6.0",
        userAgent: "com.google.visionos.youtube/1.02(RealityDevice14,1; U; CPU visionOS 25_6_0 like Mac OS X;)")

    /// The YouTube app of the Meta Quest. Also needs no sign-in or token and its streams last (checked 2026-11-05), but
    /// YouTube answers it with the bot check for many videos from some networks, so it is only the way out, not the way in.
    static let androidVR = InnertubeClient(
        name: "ANDROID_VR", id: 28, version: "1.62.27", model: "Quest 3", osName: "Android", osVersion: "12L",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        make: "Oculus", androidSdk: 32)

    func context(region: String, visitorData: String?) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": name, "clientVersion": version, "deviceMake": make, "deviceModel": model,
            "osName": osName, "osVersion": osVersion, "hl": "en", "gl": region,
        ]
        if let androidSdk { client["androidSdkVersion"] = androidSdk }
        if let visitorData { client["visitorData"] = visitorData }
        return ["client": client]
    }

    func headers(visitorData: String?) -> [String: String] {
        var headers = ["User-Agent": userAgent, "X-YouTube-Client-Name": String(id), "X-YouTube-Client-Version": version]
        if let visitorData { headers["X-Goog-Visitor-Id"] = visitorData }
        return headers
    }
}

/// Searching, listing and getting the stream addresses of YouTube videos, straight from YouTube's own web API, with
/// no account.
actor YouTubeResolver: StreamResolver {
    private let http: HTTPClient
    private let music: MusicSource
    private let region: String
    private let clients: [InnertubeClient]
    private let now: @Sendable () -> Date
    /// An identity asked for in advance, and the ask that is under way for the next one.
    private var spare: (id: String, askedAt: Date)?
    private var refill: Task<Void, Never>?

    init(http: HTTPClient = URLSessionHTTP(), music: MusicSource? = nil, region: String = "US",
         clients: [InnertubeClient] = [.visionOS, .androidVR], now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.music = music ?? MusicClient(region: { region }, http: http)
        self.region = region
        self.clients = clients
        self.now = now
    }

    // ------------------------------------------------------------------ streams

    func resolve(_ videoId: String) async throws -> Resolved {
        var lastProblem = "no answer"
        var lastError: Error?
        // Every client was told the video does not play: no other try will play it
        var unplayable = true
        // The first try is the one that takes the identity asked for in advance; the main client has a second one, after
        // anything went wrong, that asks for its own; the other clients are tried only after that
        for (attempt, client) in ([clients[0]] + clients).enumerated() {
            do {
                let visitorData = try await visitorData(for: client, fresh: attempt > 0)
                let answer = try await http.postJSON(
                    "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false",
                    body: [
                        "context": client.context(region: region, visitorData: visitorData),
                        "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true,
                    ],
                    headers: client.headers(visitorData: visitorData),
                    service: "YouTube"
                )
                var resolved = try Self.resolved(answer, videoId: videoId)
                resolved.userAgent = client.userAgent
                return resolved
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastProblem = error.localizedDescription
                lastError = error
                if (error as? ResolveFailure)?.unplayable != true { unplayable = false }
            }
        }
        if unplayable { throw LoadFailure(reason: .unplayable, message: "\(videoId) cannot be played: \(lastProblem)") }
        if let lastError, Self.isOffline(lastError) { throw LoadFailure(reason: .offline, message: "No network to get \(videoId): \(lastProblem)") }
        throw ResolveFailure(message: "Could not get a stream for \(videoId): \(lastProblem)")
    }

    /// Whether [error] says YouTube cannot be reached at all, as opposed to being slow or refusing.
    static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
                .internationalRoamingOff].contains(error.code)
    }

    /// An identity YouTube gives to a visitor; asking for streams with one is what keeps it from calling us a robot. One
    /// is asked for in advance and given out once, so that a song costs only its `player` request; one that has waited
    /// longer than [spareMaxAge] is not used. An identity kept for an hour and used for many songs was seen to get only
    /// streams that broke with 403 after their first moments, however often they were resolved again, until the app was
    /// restarted: none is used twice.
    private func visitorData(for client: InnertubeClient, fresh: Bool) async throws -> String? {
        let kept = spare
        spare = nil
        if !fresh, let kept, now().timeIntervalSince(kept.askedAt) < Self.spareMaxAge {
            askForSpare()
            return kept.id
        }
        defer { askForSpare() }
        return try await askForVisitor(client)
    }

    /// Asks for the next identity in the background, unless one is kept or already being asked for. The main client
    /// asks for it, whoever has used the last one.
    private func askForSpare() {
        guard spare == nil, refill == nil else { return }
        let client = clients[0]
        refill = Task {
            if let id = try? await askForVisitor(client) { spare = (id, now()) }
            refill = nil
        }
    }

    /// Waits until the identity being asked for in the background has come, or failed to.
    func idle() async {
        await refill?.value
    }

    private static let spareMaxAge: TimeInterval = 10 * 60

    private func askForVisitor(_ client: InnertubeClient) async throws -> String? {
        let answer = try await http.postJSON(
            "https://youtubei.googleapis.com/youtubei/v1/visitor_id?prettyPrint=false",
            body: ["context": client.context(region: region, visitorData: nil)],
            headers: client.headers(visitorData: nil),
            service: "YouTube"
        )
        return answer.at("responseContext", "visitorData").string
    }

    /// The song and its audio streams that an iPhone can play (AAC in an MP4 file), from a `player` answer.
    static func resolved(_ answer: JSON, videoId: String) throws -> Resolved {
        let status = answer.at("playabilityStatus", "status").string
        guard status == "OK" else {
            throw ResolveFailure(message: answer.at("playabilityStatus", "reason").string ?? "The video is not available (\(status ?? "no status"))",
                                 unplayable: true)
        }
        let details = answer.at("videoDetails")
        let length = details.at("lengthSeconds").int64 ?? 0
        if details.at("isLive").bool == true || length <= 0 { throw ResolveFailure(message: "Live streams cannot be played", unplayable: true) }

        let trackLoudness = Self.trackLoudness(answer)
        let sources: [AudioSource] = answer.at("streamingData", "adaptiveFormats").array.compactMap { format in
            guard let mime = format.at("mimeType").string, mime.hasPrefix("audio/mp4"), let url = format.at("url").string else { return nil }
            // A video with dubbed sound lists one stream per language: the song is the original one
            if format.at("audioTrack", "audioIsDefault").bool == false { return nil }
            let bitrate = format.at("averageBitrate").int ?? format.at("bitrate").int ?? 0
            return AudioSource(url: url, mimeType: mime, bitrateKbps: bitrate / 1000, contentLength: format.at("contentLength").int64 ?? -1,
                               itag: format.at("itag").int ?? -1, index: DashRanges.of(format),
                               loudnessDb: format.at("loudnessDb").double ?? trackLoudness)
        }.sorted { $0.bitrateKbps > $1.bitrateKbps }
        guard let best = sources.first else { throw ResolveFailure(message: "No audio stream available for \(videoId)", unplayable: true) }

        let thumbs = details.at("thumbnail", "thumbnails").array
        let thumb = thumbs.max { ($0.at("width").int ?? 0) < ($1.at("width").int ?? 0) }?.at("url").string
        let track = TrackInfo(
            videoId: videoId,
            title: details.at("title").string ?? "",
            artist: details.at("author").string ?? "",
            thumbUrl: thumb,
            durationSec: length
        )
        let videos: [VideoSource] = answer.at("streamingData", "adaptiveFormats").array.compactMap { format in
            guard let mime = format.at("mimeType").string, mime.hasPrefix("video/mp4"), let url = format.at("url").string,
                  let height = format.at("height").int, height > 0 else { return nil }
            let codec = mime.components(separatedBy: "codecs=\"").last?.components(separatedBy: "\"").first ?? ""
            return VideoSource(url: url, height: height, codec: codec, bitrateKbps: (format.at("bitrate").int ?? 0) / 1000, itag: format.at("itag").int ?? -1,
                               contentLength: format.at("contentLength").int64 ?? -1, index: DashRanges.of(format))
        }
        return Resolved(track: track, best: best, all: sources, videos: videos)
    }

    /// How far above YouTube's reference level (the `loudnessTargetLkfs` of the answer, -14) the song is, for a stream that
    /// does not say so itself: the answer gives the loudness of the whole song as an absolute number of LKFS.
    private static func trackLoudness(_ answer: JSON) -> Double? {
        let config = answer.at("playerConfig", "audioConfig")
        guard let absolute = config.at("perceptualLoudnessDb").double else { return nil }
        return absolute - (config.at("loudnessTargetLkfs").double ?? -14)
    }

    // ------------------------------------------------------------------ lists

    func search(_ query: String, limit: Int, songsOnly: Bool) async throws -> [TrackInfo] {
        if songsOnly {
            return try await music.searchSongs(query).filter { $0.durationSec > 0 }.prefix(limit).map(Self.info)
        }
        // The pages after the first are asked for until there are as many as wanted
        var found = [TrackInfo]()
        var answer = try await web("search", ["query": query, "params": "EgIQAQ%3D%3D"])
        for _ in 1...Self.maxSearchPages {
            found += Self.videos(answer)
            guard found.count < limit,
                  let next = answer.findAll("continuationItemRenderer").first?.at("continuationEndpoint", "continuationCommand", "token").string
            else { break }
            answer = try await web("search", ["continuation": next])
        }
        return Array(found.prefix(limit))
    }

    /// How many pages of a search are read to get as many results as asked for.
    private static let maxSearchPages = 10

    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistRef] {
        let answer = try await web("search", ["query": query, "params": "EgIQAw%3D%3D"])
        return Array(Self.playlists(answer).prefix(limit))
    }

    func playlist(_ playlistId: String, limit: Int) async throws -> Playlist {
        let found = try await music.playlist(playlistId)
        // Deleted and private videos show up with no length
        let tracks = found.tracks.filter { $0.durationSec > 0 }.prefix(limit).map(Self.info)
        return Playlist(title: found.title ?? "", tracks: Array(tracks))
    }

    func related(_ videoId: String, limit: Int) async throws -> [TrackInfo] {
        let answer = try await web("next", ["videoId": videoId])
        return Array(Self.lockupVideos(answer).prefix(limit))
    }

    func suggest(_ query: String) async throws -> [String] {
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "youtube"), URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "hl", value: "en"), URLQueryItem(name: "q", value: query),
        ]
        guard let url = components.url else { return [] }
        let reply = try await http.send(URLRequest(url: url))
        guard (200..<300).contains(reply.status) else { throw HTTPFailure(status: reply.status, service: "YouTube") }
        // The answer says it is ISO-8859-1: "â" or "á" come as one raw byte, which UTF-8 reads as "�". The rest of the
        // alphabet comes as \u escapes, so Latin-1 reads the whole of it
        return Self.suggestions(String(data: reply.data, encoding: .isoLatin1) ?? reply.text)
    }

    private func web(_ endpoint: String, _ fields: [String: Any]) async throws -> JSON {
        var body = fields
        body["context"] = ["client": ["clientName": "WEB", "clientVersion": "2.20260120.01.00", "hl": "en", "gl": region]]
        return try await http.postJSON(
            "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false",
            body: body,
            headers: ["User-Agent": YouTubeAgents.browser, "Origin": "https://www.youtube.com"],
            service: "YouTube"
        )
    }

    // ------------------------------------------------------------------ readers

    private static func info(_ track: MusicTrack) -> TrackInfo {
        TrackInfo(videoId: track.videoId, title: track.title, artist: track.artist, thumbUrl: track.thumbUrl, durationSec: track.durationSec)
    }

    /// The videos of a search answer. Live streams have no length and cannot be put on a shared queue.
    static func videos(_ root: JSON) -> [TrackInfo] {
        root.findAll("videoRenderer").compactMap { renderer in
            guard let id = renderer.at("videoId").string else { return nil }
            let seconds = MusicParser.seconds(renderer.at("lengthText", "simpleText").string)
            guard seconds > 0 else { return nil }
            let title = renderer.at("title", "runs").array.map { $0.at("text").string ?? "" }.joined()
            let artist = renderer.at("ownerText", "runs", "0", "text").string ?? ""
            return TrackInfo(videoId: id, title: title, artist: artist, thumbUrl: biggest(renderer.at("thumbnail", "thumbnails")), durationSec: seconds)
        }
    }

    /// The playlists of a search answer; the mixes YouTube makes up by itself have no page to list.
    static func playlists(_ root: JSON) -> [PlaylistRef] {
        root.findAll("lockupViewModel").compactMap { lockup in
            guard lockup.at("contentType").string == "LOCKUP_CONTENT_TYPE_PLAYLIST", let id = lockup.at("contentId").string,
                  !id.hasPrefix("RD") else { return nil }
            let meta = lockup.at("metadata", "lockupMetadataViewModel")
            let badges = lockup.findAll("thumbnailBadgeViewModel").compactMap { $0.at("text").string }
            let count = badges.compactMap { text in Int64(text.prefix { $0.isNumber }) }.first ?? 0
            return PlaylistRef(
                id: id,
                title: meta.at("title", "content").string ?? "",
                uploader: meta.at("metadata", "contentMetadataViewModel", "metadataRows", "0", "metadataParts", "0", "text", "content").string ?? "",
                thumbUrl: biggest(lockup.findAll("sources").first),
                songCount: count
            )
        }
    }

    /// The videos listed beside a video, from its `next` answer.
    static func lockupVideos(_ root: JSON) -> [TrackInfo] {
        root.findAll("lockupViewModel").compactMap { lockup in
            guard lockup.at("contentType").string == "LOCKUP_CONTENT_TYPE_VIDEO", let id = lockup.at("contentId").string else { return nil }
            let lengths: [Int64] = lockup.findAll("thumbnailBadgeViewModel").map { MusicParser.seconds($0.at("text").string) }
            let seconds: Int64 = lengths.first(where: { $0 > 0 }) ?? 0
            guard seconds > 0 else { return nil }
            let meta = lockup.at("metadata", "lockupMetadataViewModel")
            return TrackInfo(
                videoId: id,
                title: meta.at("title", "content").string ?? "",
                artist: meta.at("metadata", "contentMetadataViewModel", "metadataRows", "0", "metadataParts", "0", "text", "content").string ?? "",
                thumbUrl: biggest(lockup.findAll("sources").first),
                durationSec: seconds
            )
        }
    }

    /// `window.google.ac.h(["lofi",[["lofi girl",0,[512]],...]])`: the words, in order.
    static func suggestions(_ text: String) -> [String] {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close,
              let json = JSON.parse(String(text[text.index(after: open)..<close])) else { return [] }
        return json[1].array.compactMap { $0[0].string }
    }

    private static func biggest(_ list: JSON?) -> String? {
        let items = list?.array ?? []
        return items.max { ($0.at("width").int ?? 0) < ($1.at("width").int ?? 0) }?.at("url").string
    }
}
