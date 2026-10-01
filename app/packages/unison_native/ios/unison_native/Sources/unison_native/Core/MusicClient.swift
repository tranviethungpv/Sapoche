import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends a request to YouTube Music and gives back the answer.
typealias MusicTransport = (_ endpoint: String, _ body: [String: Any]) async throws -> JSON

/// YouTube Music as the website asks it, for a person who is not signed in: this is what gives radios, the related
/// page, lyrics, artists and playlists. It is not a documented API and can change, so the readers in [MusicParser]
/// give what they find and callers treat failure as "nothing to show".
struct MusicClient: MusicSource {
    static let clientName = "WEB_REMIX"

    /// The version of the website the answers are shaped for; YouTube Music stops answering very old ones.
    static let clientVersion = "1.20250310.01.00"

    /// The search filters of the website's "Songs" and "Videos" chips.
    private static let songs = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
    private static let videos = "EgWKAQIQAWoKEAkQBRAKEAMQBA=="

    /// The country whose music is shown first, as a code like "VN"; follows the phone.
    private let region: () -> String
    private let transport: MusicTransport

    init(region: @escaping () -> String = { "US" }, transport: @escaping MusicTransport) {
        self.region = region
        self.transport = transport
    }

    /// Over the network.
    init(region: @escaping () -> String = { "US" }, http: HTTPClient = URLSessionHTTP()) {
        self.init(region: region) { endpoint, body in
            try await http.postJSON(
                "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false",
                body: body,
                headers: ["Origin": "https://music.youtube.com", "User-Agent": YouTubeAgents.browser],
                service: "YouTube Music"
            )
        }
    }

    func watchNext(_ videoId: String, radio: Bool) async throws -> WatchNext {
        var fields: [String: Any] = ["videoId": videoId, "isAudioOnly": true]
        if radio { fields["playlistId"] = "RDAMVM\(videoId)" }
        return MusicParser.watchNext(try await ask("next", fields))
    }

    func related(_ relatedId: String) async throws -> Related {
        MusicParser.related(try await browse(relatedId))
    }

    func lyrics(_ lyricsId: String) async throws -> String? {
        MusicParser.lyrics(try await browse(lyricsId))
    }

    func artist(_ artistId: String) async throws -> ArtistPage {
        MusicParser.artist(artistId, try await browse(artistId))
    }

    func searchSongs(_ query: String) async throws -> [MusicTrack] {
        MusicParser.search(try await search(query, Self.songs))
    }

    func searchVideos(_ query: String) async throws -> [MusicTrack] {
        MusicParser.search(try await search(query, Self.videos))
    }

    func playlist(_ playlistId: String) async throws -> (title: String?, tracks: [MusicTrack]) {
        MusicParser.playlist(try await browse("VL" + playlistId))
    }

    // Only the shelf names of this page are meant to be read by a person; everything else is found by the words
    // YouTube Music uses in English ("Lyrics", "Related"), so those calls stay in English
    func trending(language: String) async throws -> [MusicShelf] {
        MusicParser.shelves(try await ask("browse", ["browseId": "FEmusic_home"], language: language))
    }

    private func browse(_ id: String) async throws -> JSON {
        try await ask("browse", ["browseId": id])
    }

    private func search(_ query: String, _ filter: String) async throws -> JSON {
        try await ask("search", ["query": query, "params": filter])
    }

    private func ask(_ endpoint: String, _ fields: [String: Any], language: String = "en") async throws -> JSON {
        let country = region()
        var body = fields
        body["context"] = [
            "client": [
                "clientName": Self.clientName,
                "clientVersion": Self.clientVersion,
                "hl": language,
                "gl": country.isEmpty ? "US" : country,
            ],
        ]
        return try await transport(endpoint, body)
    }
}

enum YouTubeAgents {
    static let browser = "Mozilla/5.0 (Windows NT 10.0; rv:128.0) Gecko/20100101 Firefox/128.0"
}
