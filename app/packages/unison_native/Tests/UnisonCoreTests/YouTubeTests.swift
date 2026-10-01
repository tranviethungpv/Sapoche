import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import UnisonCore

/// Answers asked for by address, from a list; remembers what it was asked.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    struct Call {
        let url: String
        let headers: [String: String]
        let body: [String: Any]
    }

    var answers: [(contains: String, status: Int, body: Data)] = []
    var calls: [Call] = []

    func answer(_ contains: String, status: Int = 200, fixture name: String) throws {
        answers.append((contains, status, try fixture(name)))
    }

    func answer(_ contains: String, status: Int = 200, text: String) {
        answers.append((contains, status, Data(text.utf8)))
    }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        let url = request.url?.absoluteString ?? ""
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let headers = Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
        calls.append(Call(url: url, headers: headers, body: body))
        guard let found = answers.first(where: { url.contains($0.contains) }) else { throw URLError(.notConnectedToInternet) }
        return HTTPReply(status: found.status, data: found.body, headers: [:])
    }
}

final class YouTubeTests: XCTestCase {
    private func resolver(_ http: FakeHTTP) -> YouTubeResolver {
        YouTubeResolver(http: http, music: MusicClient(http: http), region: "VN")
    }

    private func visitorAnswer(_ id: String = "VISITOR1") -> String {
        #"{"responseContext":{"visitorData":"\#(id)"}}"#
    }

    func testAnAnswerWithStreamsGivesTheBestAACOne() throws {
        let answer = try XCTUnwrap(JSON.parse(data: fixture("player_visionos")))
        let resolved = try YouTubeResolver.resolved(answer, videoId: "dQw4w9WgXcQ")
        XCTAssertEqual(resolved.track.title, "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)")
        XCTAssertEqual(resolved.track.artist, "Rick Astley")
        XCTAssertEqual(resolved.track.durationSec, 213)
        XCTAssertNotNil(resolved.track.thumbUrl)
        XCTAssertEqual(resolved.best.itag, 140)
        XCTAssertEqual(resolved.all.map(\.itag), [140, 139], "only what an iPhone can play, best first")
        XCTAssertTrue(resolved.all.allSatisfy { $0.mimeType.hasPrefix("audio/mp4") })
        XCTAssertGreaterThan(resolved.best.contentLength, 0)
    }

    func testAVideoThatCannotBePlayedSaysWhy() throws {
        let answer = try XCTUnwrap(JSON.parse(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you're not a bot"}}"#))
        XCTAssertThrowsError(try YouTubeResolver.resolved(answer, videoId: "x")) {
            XCTAssertEqual($0.localizedDescription, "Sign in to confirm you're not a bot")
        }
        let live = try XCTUnwrap(JSON.parse(#"{"playabilityStatus":{"status":"OK"},"videoDetails":{"isLive":true,"lengthSeconds":"0"}}"#))
        XCTAssertThrowsError(try YouTubeResolver.resolved(live, videoId: "x"))
    }

    func testResolvingAsksAsTheVisionOSAppWithAVisitorIdentity() async throws {
        let http = FakeHTTP()
        http.answer("visitor_id", text: visitorAnswer())
        try http.answer("/player", fixture: "player_visionos")
        let resolved = try await resolver(http).resolve("dQw4w9WgXcQ")
        XCTAssertEqual(resolved.best.itag, 140)

        let player = try XCTUnwrap(http.calls.first { $0.url.contains("/player") })
        XCTAssertEqual(player.headers["x-goog-visitor-id"], "VISITOR1")
        XCTAssertEqual(player.headers["x-youtube-client-name"], "101")
        XCTAssertTrue(player.headers["user-agent"]?.hasPrefix("com.google.visionos.youtube/") == true)
        let client = (player.body["context"] as? [String: Any])?["client"] as? [String: Any]
        XCTAssertEqual(client?["clientName"] as? String, "VISIONOS")
        XCTAssertEqual(client?["visitorData"] as? String, "VISITOR1")
        XCTAssertEqual(client?["gl"] as? String, "VN")
        XCTAssertEqual(player.body["videoId"] as? String, "dQw4w9WgXcQ")
    }

    func testTheVisitorIdentityIsAskedForOnce() async throws {
        let http = FakeHTTP()
        http.answer("visitor_id", text: visitorAnswer())
        try http.answer("/player", fixture: "player_visionos")
        let resolver = resolver(http)
        _ = try await resolver.resolve("dQw4w9WgXcQ")
        _ = try await resolver.resolve("dQw4w9WgXcQ")
        XCTAssertEqual(http.calls.filter { $0.url.contains("visitor_id") }.count, 1)
    }

    func testWhenTheFirstClientIsTurnedDownTheNextOneIsTried() async throws {
        let http = FakeHTTP()
        http.answer("visitor_id", text: visitorAnswer())
        // The visionOS app gets the bot check, the iPhone app gets through
        let answers = [
            #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in"}}"#,
            String(decoding: try fixture("player_visionos"), as: UTF8.self),
        ]
        let counter = Collected()
        let flaky = FlakyHTTP(base: http, answers: answers, counter: counter)
        let resolved = try await YouTubeResolver(http: flaky, music: MusicClient(http: http), region: "US").resolve("dQw4w9WgXcQ")
        XCTAssertEqual(resolved.best.itag, 140)
        XCTAssertEqual(flaky.playerNames, ["VISIONOS", "IOS"])
    }

    func testAnEveryClientThatFailsGivesAnErrorTheUserCanRead() async throws {
        let http = FakeHTTP()
        http.answer("visitor_id", text: visitorAnswer())
        http.answer("/player", text: #"{"playabilityStatus":{"status":"ERROR","reason":"Video unavailable"}}"#)
        do {
            _ = try await resolver(http).resolve("x")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Video unavailable"), error.localizedDescription)
        }
    }

    func testAWebSearchGivesVideosWithALengthAndNoLiveStreams() throws {
        let answer = try XCTUnwrap(JSON.parse(data: fixture("web_search_videos")))
        let found = YouTubeResolver.videos(answer)
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy { $0.durationSec > 0 && !$0.title.isEmpty && !$0.artist.isEmpty && $0.thumbUrl != nil })
        let live = try XCTUnwrap(JSON.parse(#"{"a":[{"videoRenderer":{"videoId":"live1","title":{"runs":[{"text":"Live"}]}}}]}"#))
        XCTAssertTrue(YouTubeResolver.videos(live).isEmpty, "a live stream has no length")
    }

    func testAPlaylistSearchGivesPlaylistsWithTheirSizes() throws {
        let answer = try XCTUnwrap(JSON.parse(data: fixture("web_search_playlists")))
        let found = YouTubeResolver.playlists(answer)
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty && !$0.id.hasPrefix("RD") })
        XCTAssertTrue(found.contains { $0.songCount > 0 && !$0.uploader.isEmpty })
    }

    func testTheVideosListedBesideAVideoComeWithTheirLength() throws {
        let answer = try XCTUnwrap(JSON.parse(data: fixture("web_next")))
        let found = YouTubeResolver.lockupVideos(answer)
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy { $0.durationSec > 0 && !$0.title.isEmpty && $0.videoId.count == 11 })
    }

    func testSuggestionsAreReadFromTheCallbackText() {
        let text = #"window.google.ac.h(["lofi g",[["lofi girl",0,[512,433]],["lofi gaming",0,[512]],["lofi gỉl",0,[512]]],{"k":1}])"#
        XCTAssertEqual(YouTubeResolver.suggestions(text), ["lofi girl", "lofi gaming", "lofi gỉl"])
        XCTAssertEqual(YouTubeResolver.suggestions("not it"), [])
    }

    func testAPlaylistIsListedByItsSongsWithoutTheOnesThatHaveNoLength() async throws {
        let http = FakeHTTP()
        try http.answer("music.youtube.com", fixture: "music_playlist")
        let playlist = try await resolver(http).playlist("PLx", limit: 3)
        XCTAssertEqual(playlist.title, "Popular Music Videos")
        XCTAssertEqual(playlist.tracks.count, 3)
    }
}

/// Answers the first calls to `player` with the given texts, one after the other, and everything else as [base] does.
final class FlakyHTTP: HTTPClient, @unchecked Sendable {
    let base: FakeHTTP
    var answers: [String]
    let counter: Collected
    var playerNames: [String] = []

    init(base: FakeHTTP, answers: [String], counter: Collected) {
        self.base = base
        self.answers = answers
        self.counter = counter
    }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        guard request.url?.absoluteString.contains("/player") == true else { return try await base.send(request) }
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        playerNames.append(((body["context"] as? [String: Any])?["client"] as? [String: Any])?["clientName"] as? String ?? "")
        let text = answers.isEmpty ? "{}" : answers.removeFirst()
        return HTTPReply(status: 200, data: Data(text.utf8), headers: [:])
    }
}
