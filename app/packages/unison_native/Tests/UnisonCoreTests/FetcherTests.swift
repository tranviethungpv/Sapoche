import XCTest
@testable import UnisonCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers range requests for a file of known size, the way YouTube does, and keeps what was asked.
private final class Server: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var ranges: [String] = []
    nonisolated(unsafe) static var ignoreRanges = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let total = Server.body.count
        let asked = request.value(forHTTPHeaderField: "Range") ?? ""
        Server.ranges.append(asked)
        var status = 200
        var data = Server.body
        var headers = ["Content-Length": String(total)]
        if !Server.ignoreRanges, asked.hasPrefix("bytes="), let dash = asked.firstIndex(of: "-"),
           let from = Int(asked[asked.index(asked.startIndex, offsetBy: 6)..<dash]) {
            let to = min(Int(asked[asked.index(after: dash)...]) ?? total - 1, total - 1)
            data = Server.body.subdata(in: from..<(to + 1))
            status = 206
            headers = ["Content-Range": "bytes \(from)-\(to)/\(total)", "Content-Length": String(data.count)]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FetcherTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("fetch-\(UUID().uuidString).part")
        Server.ranges = []
        Server.ignoreRanges = false
    }

    private func fetcher() -> URLSessionFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Server.self]
        return URLSessionFetcher(configuration: configuration)
    }

    private func bytes(_ count: Int) -> Data { Data((0..<count).map { UInt8($0 % 251) }) }

    func testASmallSongIsOneRequest() async throws {
        Server.body = bytes(1000)
        let size = try await fetcher().fetch(URL(string: "https://example.invalid/a")!, headers: [:], to: file)
        XCTAssertEqual(size, 1000)
        XCTAssertEqual(try Data(contentsOf: file), Server.body)
        XCTAssertEqual(Server.ranges, ["bytes=0-\(URLSessionFetcher.chunkBytes - 1)"])
    }

    func testALongSongIsFetchedInRangesNoneLongerThanTheChunkAndPutBackTogether() async throws {
        let chunk = Int(URLSessionFetcher.chunkBytes)
        Server.body = bytes(chunk * 2 + 12_345)
        let size = try await fetcher().fetch(URL(string: "https://example.invalid/b")!, headers: [:], to: file)
        XCTAssertEqual(size, Int64(chunk * 2 + 12_345))
        XCTAssertEqual(try Data(contentsOf: file), Server.body)
        XCTAssertEqual(Server.ranges, ["bytes=0-\(chunk - 1)", "bytes=\(chunk)-\(chunk * 2 - 1)", "bytes=\(chunk * 2)-\(chunk * 3 - 1)"])
    }

    func testAFewBytesAreAskedForAsOneRange() async throws {
        Server.body = bytes(5000)
        let data = try await fetcher().bytes(URL(string: "https://example.invalid/d")!, range: 723...1078, headers: ["User-Agent": "ua"])
        XCTAssertEqual(data, Server.body.subdata(in: 723..<1079))
        XCTAssertEqual(Server.ranges, ["bytes=723-1078"])
    }

    func testAFewBytesFromAServerThatIgnoresRangesAreAFailure() async throws {
        Server.body = bytes(5000)
        Server.ignoreRanges = true
        do {
            _ = try await fetcher().bytes(URL(string: "https://example.invalid/e")!, range: 10...20, headers: [:])
            XCTFail("expected a failure")
        } catch {}
    }

    func testAServerThatSendsTheWholeFileForARangeIsTakenAtItsWord() async throws {
        Server.body = bytes(5000)
        Server.ignoreRanges = true
        let size = try await fetcher().fetch(URL(string: "https://example.invalid/c")!, headers: [:], to: file)
        XCTAssertEqual(size, 5000)
        XCTAssertEqual(try Data(contentsOf: file), Server.body)
    }
}
