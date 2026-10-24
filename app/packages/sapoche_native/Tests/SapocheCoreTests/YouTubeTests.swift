import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SapocheCore

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

    func testEveryResolveAsksForANewVisitorIdentity() async throws {
        let http = FakeHTTP()
        http.answer("visitor_id", text: visitorAnswer())
        try http.answer("/player", fixture: "player_visionos")
        let resolver = resolver(http)
        _ = try await resolver.resolve("dQw4w9WgXcQ")
        _ = try await resolver.resolve("dQw4w9WgXcQ")
        XCTAssertEqual(http.calls.filter { $0.url.contains("visitor_id") }.count, 2, "an identity is not kept from one resolve to the next")
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

    func testAVideoEveryClientIsToldDoesNotPlayIsNotTriedAgain() async throws {
        let http = FakeHTTP()
        http.answer("visitor_id", text: visitorAnswer())
        http.answer("/player", text: #"{"playabilityStatus":{"status":"ERROR","reason":"Video unavailable"}}"#)
        do {
            _ = try await resolver(http).resolve("x")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? LoadFailure)?.reason, .unplayable, "\(error)")
        }
    }

    func testWithoutANetworkTheResolveSaysSo() async throws {
        let http = FakeHTTP() // answers nothing: every request fails as with no network
        do {
            _ = try await resolver(http).resolve("x")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? LoadFailure)?.reason, .offline, "\(error)")
        }
    }

    func testAServerThatFailsIsNeitherOfflineNorUnplayable() async throws {
        let http = FakeHTTP()
        http.answer("visitor_id", text: visitorAnswer())
        http.answer("/player", status: 500, text: "oops")
        do {
            _ = try await resolver(http).resolve("x")
            XCTFail("expected a failure")
        } catch {
            XCTAssertNil(error as? LoadFailure, "a server error may pass: trying again is worth it")
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

    func testASearchReadsPagesUntilThereAreAsManyVideosAsAskedFor() async throws {
        func video(_ id: String) -> String {
            #"{"videoRenderer":{"videoId":"\#(id)","title":{"runs":[{"text":"T \#(id)"}]},"lengthText":{"simpleText":"3:00"},"ownerText":{"runs":[{"text":"A"}]}}}"#
        }
        func page(_ ids: [String], next: String?) -> String {
            let token = next.map { #",{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"\#($0)"}}}}"# } ?? ""
            return "{\"items\":[\(ids.map(video).joined(separator: ","))\(token)]}"
        }
        let http = FakeHTTP()
        // The same address answers every page, so the answers are told apart by what the request holds
        let pager = PagedHTTP(base: http, pages: ["first": page(["a", "b"], next: "T1"), "T1": page(["c", "d"], next: "T2"), "T2": page(["e"], next: nil)])
        let youtube = YouTubeResolver(http: pager, music: MusicClient(http: pager), region: "VN")
        let two = try await youtube.search("q", limit: 2, songsOnly: false)
        XCTAssertEqual(two.map(\.videoId), ["a", "b"])
        XCTAssertEqual(pager.asked, ["first"], "the first page was enough")
        pager.asked = []
        let five = try await youtube.search("q", limit: 20, songsOnly: false)
        XCTAssertEqual(five.map(\.videoId), ["a", "b", "c", "d", "e"], "it ends where the pages end")
        XCTAssertEqual(pager.asked, ["first", "T1", "T2"])
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

    func testSuggestionsKeepTheVietnameseLettersOfALatin1Answer() async throws {
        // As Google sends it: "â" and "á" are single bytes (0xE2, 0xE1), "ỹ" and "ổ" are escapes
        var bytes = Data(#"window.google.ac.h(["m",[["m\u1EF9 t"#.utf8)
        bytes.append(0xE2)
        bytes.append(contentsOf: Data(#"m",0],["h"#.utf8))
        bytes.append(0xE1)
        bytes.append(contentsOf: Data(#"t t\u1ED5ng",0]]])"#.utf8))
        let http = FakeHTTP()
        http.answers.append(("suggestqueries", 200, bytes))
        let found = try await resolver(http).suggest("m")
        XCTAssertEqual(found, ["mỹ tâm", "hát tổng"])
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

/// Answers a search by what its body holds: the continuation token, or "first" for the first page.
final class PagedHTTP: HTTPClient, @unchecked Sendable {
    let base: FakeHTTP
    let pages: [String: String]
    var asked: [String] = []

    init(base: FakeHTTP, pages: [String: String]) {
        self.base = base
        self.pages = pages
    }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        guard request.url?.absoluteString.contains("/search") == true else { return try await base.send(request) }
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let key = body["continuation"] as? String ?? "first"
        asked.append(key)
        return HTTPReply(status: 200, data: Data((pages[key] ?? "{}").utf8), headers: [:])
    }
}
