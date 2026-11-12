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
    /// Answers every `visitor_id` with a different identity, VISITOR1, VISITOR2, ...
    var numberedVisitors = false

    func answer(_ contains: String, status: Int = 200, fixture name: String) throws {
        answers.append((contains, status, try fixture(name)))
    }

    func answer(_ contains: String, status: Int = 200, text: String) {
        answers.append((contains, status, Data(text.utf8)))
    }

    /// The background ask for the next identity and a resolve send at the same time.
    private let lock = NSLock()

    func send(_ request: URLRequest) async throws -> HTTPReply {
        let url = request.url?.absoluteString ?? ""
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let headers = Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
        let number: Int? = lock.withLock {
            calls.append(Call(url: url, headers: headers, body: body))
            return numberedVisitors && url.contains("visitor_id") ? calls.filter { $0.url.contains("visitor_id") }.count : nil
        }
        if let number {
            return HTTPReply(status: 200, data: Data(#"{"responseContext":{"visitorData":"VISITOR\#(number)"}}"#.utf8), headers: [:])
        }
        guard let found = answers.first(where: { url.contains($0.contains) }) else { throw URLError(.notConnectedToInternet) }
        return HTTPReply(status: found.status, data: found.body, headers: [:])
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_000

    var now: Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }

    func advance(_ by: TimeInterval) { lock.withLock { seconds += by } }
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

    func testEachStreamCarriesHowLoudTheSongIs() throws {
        let loud = try YouTubeResolver.resolved(XCTUnwrap(JSON.parse(data: fixture("player_visionos_loud"))), videoId: "bNp9pn0ni3I")
        XCTAssertEqual(try XCTUnwrap(loud.best.loudnessDb), 6.55, accuracy: 0.001)
        let quiet = try YouTubeResolver.resolved(XCTUnwrap(JSON.parse(data: fixture("player_visionos"))), videoId: "dQw4w9WgXcQ")
        XCTAssertEqual(try XCTUnwrap(quiet.best.loudnessDb), 0.99, accuracy: 0.001)
    }

    func testWithoutALoudnessOfItsOwnAStreamTakesTheOneOfTheWholeSongAgainstTheReferenceLevel() throws {
        var text = String(decoding: try fixture("player_visionos_loud"), as: UTF8.self)
        text = text.replacingOccurrences(of: #""loudnessDb": "#, with: #""unusedKey": "#)
        let resolved = try YouTubeResolver.resolved(XCTUnwrap(JSON.parse(text)), videoId: "x")
        XCTAssertEqual(try XCTUnwrap(resolved.best.loudnessDb), 6.55, accuracy: 0.001, "-7.45 LKFS against the target of -14")
        let unknown = try YouTubeResolver.resolved(XCTUnwrap(JSON.parse(text.replacingOccurrences(of: #""perceptualLoudnessDb""#, with: #""unusedKey2""#))), videoId: "x")
        XCTAssertNil(unknown.best.loudnessDb)
    }

    func testADubbedTrackIsNotTheSong() throws {
        let text = #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"lengthSeconds":"60"},"streamingData":{"adaptiveFormats":["# +
            #"{"itag":140,"url":"https://example.invalid/a","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","averageBitrate":129000,"audioTrack":{"audioIsDefault":false}},"# +
            #"{"itag":139,"url":"https://example.invalid/b","mimeType":"audio/mp4; codecs=\"mp4a.40.5\"","averageBitrate":48000,"audioTrack":{"audioIsDefault":true}}]}}"#
        XCTAssertEqual(try YouTubeResolver.resolved(XCTUnwrap(JSON.parse(text)), videoId: "x").all.map(\.itag), [139])
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

    func testNoVisitorIdentityIsUsedForTwoResolves() async throws {
        let http = FakeHTTP()
        http.numberedVisitors = true
        try http.answer("/player", fixture: "player_visionos")
        let resolver = resolver(http)
        for _ in 0..<3 {
            _ = try await resolver.resolve("dQw4w9WgXcQ")
            await resolver.idle()
        }
        let used = http.calls.filter { $0.url.contains("/player") }.compactMap { $0.headers["x-goog-visitor-id"] }
        XCTAssertEqual(used.count, 3)
        XCTAssertEqual(Set(used).count, 3, "an identity is not kept from one resolve to the next: \(used)")
    }

    func testTheIdentityOfTheNextResolveIsAskedForInAdvance() async throws {
        let http = FakeHTTP()
        http.numberedVisitors = true
        try http.answer("/player", fixture: "player_visionos")
        let resolver = resolver(http)
        _ = try await resolver.resolve("dQw4w9WgXcQ") // the first one has none in advance, and asks for the next
        await resolver.idle()
        _ = try await resolver.resolve("dQw4w9WgXcQ")
        let used = http.calls.filter { $0.url.contains("/player") }.compactMap { $0.headers["x-goog-visitor-id"] }
        XCTAssertEqual(used, ["VISITOR1", "VISITOR2"], "the second resolve used the identity that was asked for after the first")
        await resolver.idle()
        XCTAssertEqual(http.calls.filter { $0.url.contains("visitor_id") }.count, 3, "and one more was asked for after it")
    }

    func testAnIdentityThatWaitedTooLongIsNotUsed() async throws {
        let http = FakeHTTP()
        http.numberedVisitors = true
        try http.answer("/player", fixture: "player_visionos")
        let clock = TestClock()
        let resolver = YouTubeResolver(http: http, music: MusicClient(http: http), region: "US", now: { clock.now })
        _ = try await resolver.resolve("dQw4w9WgXcQ")
        await resolver.idle()
        clock.advance(11 * 60)
        _ = try await resolver.resolve("dQw4w9WgXcQ")
        let used = http.calls.filter { $0.url.contains("/player") }.compactMap { $0.headers["x-goog-visitor-id"] }
        XCTAssertEqual(used, ["VISITOR1", "VISITOR3"], "VISITOR2 was asked for in advance but is too old")
    }

    func testWhenTheFirstTryIsTurnedDownTheNextOneAsksWithItsOwnIdentity() async throws {
        let http = FakeHTTP()
        http.numberedVisitors = true
        // The first identity gets the bot check, the second gets through
        let answers = [
            #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in"}}"#,
            String(decoding: try fixture("player_visionos"), as: UTF8.self),
        ]
        let counter = Collected()
        let flaky = FlakyHTTP(base: http, answers: answers, counter: counter)
        let resolved = try await YouTubeResolver(http: flaky, music: MusicClient(http: http), region: "US").resolve("dQw4w9WgXcQ")
        XCTAssertEqual(resolved.best.itag, 140)
        XCTAssertEqual(flaky.playerNames, ["VISIONOS", "VISIONOS"], "the iPhone app's streams break after 8 KB, so it is not a way out")
        XCTAssertEqual(flaky.visitors.count, 2)
        XCTAssertNotEqual(flaky.visitors[0], flaky.visitors[1], "the second try does not use what was turned down")
    }

    func testWhenTheMainClientIsTurnedDownTwiceTheQuestClientIsAsked() async throws {
        let http = FakeHTTP()
        http.numberedVisitors = true
        let turnedDown = #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you're not a bot"}}"#
        let answers = [turnedDown, turnedDown, String(decoding: try fixture("player_visionos"), as: UTF8.self)]
        let flaky = FlakyHTTP(base: http, answers: answers, counter: Collected())
        let resolved = try await YouTubeResolver(http: flaky, music: MusicClient(http: http), region: "US").resolve("dQw4w9WgXcQ")
        XCTAssertEqual(resolved.best.itag, 140)
        XCTAssertEqual(flaky.playerNames, ["VISIONOS", "VISIONOS", "ANDROID_VR"], "the main client gets its second try before another one is asked")
        XCTAssertEqual(Set(flaky.visitors).count, 3, "each try has an identity of its own")
        XCTAssertTrue(resolved.userAgent.hasPrefix("com.google.android.apps.youtube.vr.oculus/"),
                      "the stream is fetched the way the client that gave it fetches: \(resolved.userAgent)")
    }

    func testTheQuestClientIntroducesItselfAsAQuest() {
        let client = try! XCTUnwrap(InnertubeClient.androidVR.context(region: "US", visitorData: "V")["client"] as? [String: Any])
        XCTAssertEqual(client["clientName"] as? String, "ANDROID_VR")
        XCTAssertEqual(client["deviceMake"] as? String, "Oculus")
        XCTAssertEqual(client["androidSdkVersion"] as? Int, 32)
        let visionOS = try! XCTUnwrap(InnertubeClient.visionOS.context(region: "US", visitorData: nil)["client"] as? [String: Any])
        XCTAssertEqual(visionOS["deviceMake"] as? String, "Apple")
        XCTAssertNil(visionOS["androidSdkVersion"])
    }

    func testTheIdentityKeptInAdvanceIsAlwaysAskedForByTheMainClient() async throws {
        let http = FakeHTTP()
        http.numberedVisitors = true
        let turnedDown = #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in"}}"#
        let played = String(decoding: try fixture("player_visionos"), as: UTF8.self)
        let flaky = FlakyHTTP(base: http, answers: [turnedDown, turnedDown, played, played], counter: Collected())
        let resolver = YouTubeResolver(http: flaky, music: MusicClient(http: http), region: "US")
        _ = try await resolver.resolve("dQw4w9WgXcQ")
        await resolver.idle()
        // The next song takes what was kept in advance. Which call asked for it is not told by the order of the calls: the
        // background ask can be sent before or after the Quest client's own, as the two run at once. What is kept is told
        // by the identity the next song uses: VISITORn is the nth `visitor_id` call, and that call was made by the main
        // client, not by the Quest client, whose try was its own.
        _ = try await resolver.resolve("dQw4w9WgXcQ")
        await resolver.idle()
        let askers = http.calls.filter { $0.url.contains("visitor_id") }
            .compactMap { (($0.body["context"] as? [String: Any])?["client"] as? [String: Any])?["clientName"] as? String }
        let used = try XCTUnwrap(flaky.visitors.last)
        let number = try XCTUnwrap(Int(used.dropFirst("VISITOR".count)), "an identity of the test: \(used)")
        XCTAssertEqual(askers[number - 1], "VISIONOS", "what the Quest client's try left in advance is not for the next song: \(used) was asked by \(askers[number - 1]) in \(askers)")
        XCTAssertEqual(askers.filter { $0 == "ANDROID_VR" }.count, 1, "the Quest client asked only for its own try: \(askers)")
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
    var visitors: [String] = []

    init(base: FakeHTTP, answers: [String], counter: Collected) {
        self.base = base
        self.answers = answers
        self.counter = counter
    }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        guard request.url?.absoluteString.contains("/player") == true else { return try await base.send(request) }
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        playerNames.append(((body["context"] as? [String: Any])?["client"] as? [String: Any])?["clientName"] as? String ?? "")
        visitors.append(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") ?? "")
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
