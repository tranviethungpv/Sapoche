import XCTest
@testable import SapocheCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a test moves along to make the memory of the servers run out.
private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000)
}

/// What the log of the servers was told, from whatever thread told it.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []

    func add(_ line: String) {
        lock.lock()
        all.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
}

/// The servers of an address, which answer a range of a file of known size, or fail as a server that cannot be reached does.
private final class Servers: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var failing: [String: URLError.Code] = [:]
    /// Servers that take the request and never answer.
    nonisolated(unsafe) static var silent: Set<String> = []
    /// Servers that answer, after this many seconds.
    nonisolated(unsafe) static var slow: [String: TimeInterval] = [:]
    nonisolated(unsafe) static var status: [String: Int] = [:]
    nonisolated(unsafe) static var asked: [String] = []
    static let body = Data((0..<5000).map { UInt8($0 % 251) })

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Servers.asked.append(host)
        if Servers.silent.contains(host) { return }
        if let code = Servers.failing[host] {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        if let delay = Servers.slow[host] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.answer(host) }
        } else {
            answer(host)
        }
    }

    private func answer(_ host: String) {
        let total = Servers.body.count
        let asked = request.value(forHTTPHeaderField: "Range") ?? ""
        var from = 0
        var to = total - 1
        if asked.hasPrefix("bytes="), let dash = asked.firstIndex(of: "-"),
           let start = Int(asked[asked.index(asked.startIndex, offsetBy: 6)..<dash]) {
            from = start
            to = min(Int(asked[asked.index(after: dash)...]) ?? total - 1, total - 1)
        }
        let data = Servers.body.subdata(in: from..<(to + 1))
        let status = Servers.status[host] ?? 206
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": "bytes \(from)-\(to)/\(total)", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class StreamHostsTests: XCTestCase {
    private let clock = Clock()
    private let first = "rr1---sn-aaa.googlevideo.com"
    private let second = "rr1---sn-bbb.googlevideo.com"

    override func setUp() {
        Servers.failing = [:]
        Servers.silent = []
        Servers.slow = [:]
        Servers.status = [:]
        Servers.asked = []
    }

    private func hosts() -> StreamHosts { StreamHosts(now: { [clock] in clock.now }) }

    private func address(server: String = "sn-aaa", mn: String? = "sn-aaa,sn-bbb") -> URL {
        URL(string: "https://rr1---\(server).googlevideo.com/videoplayback?expire=1" + (mn.map { "&mn=\($0)" } ?? "") + "&sig=x")!
    }

    private func hostsOf(_ url: URL, _ list: StreamHosts) -> [String] { list.candidates(for: url).map { $0.host ?? "" } }

    func testTheServersAnAddressListsAreTriedInTheOrderItListsThem() {
        XCTAssertEqual(hostsOf(address(), hosts()), [first, second])
    }

    func testOnlyTheNameOfTheServerChangesNothingElseOfTheAddress() {
        let other = hosts().candidates(for: address()).last
        XCTAssertEqual(other?.absoluteString, address().absoluteString.replacingOccurrences(of: "sn-aaa.", with: "sn-bbb."))
    }

    func testAnAddressThatListsTheServerItNamesLastIsReadFromItFirst() {
        XCTAssertEqual(hostsOf(address(server: "sn-bbb", mn: "sn-bbb,sn-aaa"), hosts()), [second, first])
    }

    func testAnAddressWithNoOtherServerIsReadFromTheOneItNames() {
        let list = hosts()
        XCTAssertEqual(hostsOf(address(mn: nil), list).count, 1)
        XCTAssertEqual(hostsOf(address(mn: "sn-aaa"), list).count, 1)
        // The list does not hold the server the address names: not an address this knows how to read
        XCTAssertEqual(hostsOf(address(mn: "sn-ccc,sn-ddd"), list).count, 1)
    }

    func testTheListIsReadWhenItsCommaIsWrittenAsPercentTwoC() {
        XCTAssertEqual(hostsOf(address(mn: "sn-aaa%2Csn-bbb"), hosts()), [first, second])
    }

    func testWhatIsNotAStreamServerIsLeftAlone() {
        let list = hosts()
        for text in ["https://redirector.googlevideo.com/videoplayback?mn=sn-aaa,sn-bbb",
                     "https://rr1---sn-aaa.example.com/videoplayback?mn=sn-aaa,sn-bbb",
                     "https://music.youtube.com/youtubei/v1/player?mn=sn-aaa,sn-bbb"] {
            XCTAssertEqual(list.candidates(for: URL(string: text)!).count, 1, text)
        }
    }

    func testAServerThatCouldNotBeConnectedToGoesLastForAWhileAndThenComesBack() {
        let list = hosts()
        list.markUnreachable(address())
        XCTAssertEqual(hostsOf(address(), list), [second, first])
        clock.now = clock.now.addingTimeInterval(StreamHosts.rememberSeconds - 1)
        XCTAssertEqual(hostsOf(address(), list).first, second)
        clock.now = clock.now.addingTimeInterval(1)
        XCTAssertEqual(hostsOf(address(), list).first, first)
    }

    func testTheServersAreRememberedByNameWhateverTheAddress() {
        let list = hosts()
        list.markUnreachable(address())
        let another = URL(string: "https://\(first)/videoplayback?id=2&mn=sn-aaa,sn-bbb")!
        XCTAssertEqual(hostsOf(another, list).first, second)
    }

    func testTheAddressAsAStringChangesOnlyWhenAnotherServerIsBetter() {
        let list = hosts()
        let text = address().absoluteString
        XCTAssertEqual(list.preferred(text), text)
        list.markUnreachable(address())
        XCTAssertEqual(list.preferred(text), text.replacingOccurrences(of: "sn-aaa.", with: "sn-bbb."))
        XCTAssertEqual(list.preferred("not an address"), "not an address")
    }

    func testAFailureToConnectIsToldFromOtherFailures() {
        XCTAssertTrue(StreamHosts.isConnectFailure(URLError(.cannotConnectToHost), receivedNothing: true))
        XCTAssertTrue(StreamHosts.isConnectFailure(URLError(.timedOut), receivedNothing: true))
        // A timeout after the answer began is a stall, which another server does not mend
        XCTAssertFalse(StreamHosts.isConnectFailure(URLError(.timedOut), receivedNothing: false))
        XCTAssertFalse(StreamHosts.isConnectFailure(URLError(.networkConnectionLost), receivedNothing: true))
        // No name for the server, or no network at all, says nothing of the server
        XCTAssertFalse(StreamHosts.isConnectFailure(URLError(.cannotFindHost), receivedNothing: true))
        XCTAssertFalse(StreamHosts.isConnectFailure(URLError(.notConnectedToInternet), receivedNothing: true))
        XCTAssertFalse(StreamHosts.isConnectFailure(URLError(.cancelled), receivedNothing: true))
        XCTAssertFalse(StreamHosts.isConnectFailure(HTTPFailure(status: 403, service: "YouTube"), receivedNothing: true))
    }

    // ------------------------------------------------------------------ the fetcher

    private func fetcher(_ list: StreamHosts, shortWait: TimeInterval = URLSessionFetcher.shortWaitSeconds) -> URLSessionFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Servers.self]
        return URLSessionFetcher(configuration: configuration, hosts: list, shortWait: shortWait)
    }

    func testAServerThatCannotBeConnectedToIsReadFromAnotherAndNotTriedFirstAgain() async throws {
        let list = hosts()
        let log = Lines()
        list.setLog { log.add($0) }
        Servers.failing[first] = .cannotConnectToHost

        let one = try await fetcher(list).bytes(address(), range: 10...19, headers: [:])
        let two = try await fetcher(list).bytes(address(), range: 20...29, headers: [:])

        XCTAssertEqual(one, Servers.body.subdata(in: 10..<20))
        XCTAssertEqual(two, Servers.body.subdata(in: 20..<30))
        XCTAssertEqual(Servers.asked, [first, second, second])
        XCTAssertEqual(log.lines.count, 1)
        XCTAssertTrue(log.lines[0].contains("\(first) could not be connected to") && log.lines[0].contains("trying \(second)"), log.lines[0])
    }

    func testAServerThatDoesNotAnswerIsGivenUpOnToo() async throws {
        let list = hosts()
        Servers.failing[first] = .timedOut
        let data = try await fetcher(list).bytes(address(), range: 0...9, headers: [:])
        XCTAssertEqual(data, Servers.body.subdata(in: 0..<10))
        XCTAssertEqual(Servers.asked, [first, second])
    }

    func testAServerThatNeverBeginsItsAnswerIsGivenUpOnAfterTheShortWait() async throws {
        let list = hosts()
        Servers.silent = [first]
        let started = Date()
        let data = try await fetcher(list, shortWait: 0.3).bytes(address(), range: 0...9, headers: [:])
        XCTAssertEqual(data, Servers.body.subdata(in: 0..<10))
        XCTAssertEqual(Servers.asked, [first, second])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // And it is not waited for again
        _ = try await fetcher(list, shortWait: 0.3).bytes(address(), range: 0...9, headers: [:])
        XCTAssertEqual(Servers.asked, [first, second, second])
    }

    func testTheLastServerToTryIsGivenTheUsualTimeNotTheShortOne() async throws {
        let list = hosts()
        list.markUnreachable(address())
        // The server that was fine comes first and is down; the one that could not be reached lately is the last resort,
        // and a slow network is allowed to be slow there
        Servers.failing[second] = .cannotConnectToHost
        Servers.slow[first] = 0.6
        let data = try await fetcher(list, shortWait: 0.2).bytes(address(), range: 0...9, headers: [:])
        XCTAssertEqual(data, Servers.body.subdata(in: 0..<10))
        XCTAssertEqual(Servers.asked, [second, first])
    }

    func testAWholeSongIsFetchedFromTheOtherServerToo() async throws {
        let list = hosts()
        Servers.failing[first] = .cannotConnectToHost
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: file) }
        let size = try await fetcher(list).fetch(address(), headers: [:], to: file)
        XCTAssertEqual(size, Int64(Servers.body.count))
        XCTAssertEqual(try Data(contentsOf: file), Servers.body)
    }

    func testAnAnswerThatIsNotASuccessIsTheAnswerNotAReasonToGoToAnotherServer() async {
        let list = hosts()
        Servers.status[first] = 403
        do {
            _ = try await fetcher(list).bytes(address(), range: 0...9, headers: [:])
            XCTFail("expected a failure")
        } catch {}
        XCTAssertEqual(Servers.asked, [first])
    }

    func testWhenNoServerCanBeConnectedToTheFailureIsTheOneOfTheFirst() async {
        let list = hosts()
        Servers.failing[first] = .cannotConnectToHost
        Servers.failing[second] = .timedOut
        do {
            _ = try await fetcher(list).bytes(address(), range: 0...9, headers: [:])
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertEqual(Servers.asked, [first, second])
    }

    func testAnAddressWithNoOtherServerFailsAsItAlwaysDid() async {
        let list = hosts()
        Servers.failing[first] = .cannotConnectToHost
        do {
            _ = try await fetcher(list).bytes(address(mn: nil), range: 0...9, headers: [:])
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertEqual(Servers.asked, [first])
    }
}
