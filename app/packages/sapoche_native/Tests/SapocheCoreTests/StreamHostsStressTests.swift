import XCTest
@testable import SapocheCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How each server of the address answers, and which were asked.
private final class Chaos: URLProtocol, @unchecked Sendable {
    enum Outcome: CaseIterable {
        case ok, refused, connectTimeout, noAddress, dnsFailed, noRoute
        case http403, http404, http416, http500, reset, tlsBroken

        /// The failure of the server itself rather than an answer of its own, which another server can mend.
        var isConnect: Bool {
            switch self {
            case .refused, .connectTimeout, .noAddress, .dnsFailed: return true
            default: return false
            }
        }

        var error: URLError.Code? {
            switch self {
            case .refused: return .cannotConnectToHost
            case .connectTimeout: return .timedOut
            case .noAddress: return .cannotFindHost
            case .dnsFailed: return .dnsLookupFailed
            case .noRoute: return .networkConnectionLost
            case .reset: return .networkConnectionLost
            case .tlsBroken: return .secureConnectionFailed
            default: return nil
            }
        }

        var status: Int {
            switch self {
            case .http403: return 403
            case .http404: return 404
            case .http416: return 416
            case .http500: return 500
            default: return 206
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: Outcome] = [:]
    nonisolated(unsafe) private static var log: [String] = []
    static let body = Data((0..<2000).map { UInt8($0 % 251) })

    static func set(_ outcomes: [String: Outcome]) {
        lock.lock(); table = outcomes; log = []; lock.unlock()
    }

    static var asked: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private static func outcome(of host: String) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        log.append(host)
        return table[host] ?? .refused
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let outcome = Chaos.outcome(of: host)
        if let code = outcome.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let data = Chaos.body.subdata(in: 0..<10)
        let response = HTTPURLResponse(url: request.url!, statusCode: outcome.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": "bytes 0-9/\(Chaos.body.count)", "Content-Length": "10"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A seeded generator, so that a failure is the same failure on the next run.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Every way the servers of one address can answer, in every combination, against what the fallback must never do:
/// be worse than reading from the server the address names. (2026-11-14: a made-up name that had no address, and a
/// server remembered as down, made every retry of a song fail for five minutes while the real server was fine.)
final class StreamHostsStressTests: XCTestCase {
    private let clock = ClockBox()
    private let named = "rr12---sn-aaa.googlevideo.com"
    private let others = ["rr1---sn-bbb.googlevideo.com", "rr1---sn-ccc.googlevideo.com"]
    private var all: [String] { [named] + others }

    private final class ClockBox: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private func address() -> URL {
        URL(string: "https://\(named)/videoplayback?expire=1&mn=sn-aaa,sn-bbb,sn-ccc&sig=x")!
    }

    private func fetcher(_ hosts: StreamHosts) -> URLSessionFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Chaos.self]
        return URLSessionFetcher(configuration: configuration, hosts: hosts, shortWait: 5)
    }

    private func hosts() -> StreamHosts { StreamHosts(now: { [clock] in clock.now }) }

    /// One read, checked against what the outcomes make of it.
    private func read(_ fetcher: URLSessionFetcher, _ outcomes: [String: Chaos.Outcome], file: StaticString = #filePath, line: UInt = #line) async {
        Chaos.set(outcomes)
        let own = outcomes[named]!
        let someoneServes = outcomes.values.contains(.ok)
        let what = "plan=\(outcomes.map { "\($0.key.prefix(14))=\($0.value)" }.sorted()) asked=\(Chaos.asked)"
        var data: Data?
        var failure: Error?
        do {
            data = try await fetcher.bytes(address(), range: 0...9, headers: [:])
        } catch {
            failure = error
        }
        let asked = Chaos.asked
        XCTAssertEqual(Set(asked).count, asked.count, "a server asked twice: \(what)", file: file, line: line)
        XCTAssertTrue(asked.allSatisfy { all.contains($0) }, what, file: file, line: line)

        /// Is the failure the one this server gives?
        func isTheFailureOf(_ outcome: Chaos.Outcome) -> Bool {
            if let code = outcome.error { return (failure as? URLError)?.code == code }
            return (failure as? HTTPFailure)?.status == outcome.status
        }
        if own == .ok {
            XCTAssertNotNil(data, "the named server is fine and the read failed: \(what) \(String(describing: failure))", file: file, line: line)
        } else if own.isConnect {
            if someoneServes {
                XCTAssertNotNil(data, "a server serves and the read failed: \(what) \(String(describing: failure))", file: file, line: line)
            } else {
                XCTAssertNil(data, what, file: file, line: line)
                XCTAssertTrue(isTheFailureOf(own), "not the failure of the named server: \(what) \(String(describing: failure))", file: file, line: line)
            }
        } else if data == nil {
            // The named server answered badly and no server gave the stream first: the answer is the named one's, never a substitute's
            XCTAssertTrue(isTheFailureOf(own), "the failure of a substitute was the answer: \(what) \(String(describing: failure))", file: file, line: line)
        }
    }

    private func plan(_ rng: inout Seeded) -> [String: Chaos.Outcome] {
        Dictionary(uniqueKeysWithValues: all.map { ($0, Chaos.Outcome.allCases.randomElement(using: &rng)!) })
    }

    func testRandomCombinationsOverALongRunWithTheClockJumping() async {
        var rng = Seeded(21)
        let list = hosts()
        let reader = fetcher(list)
        for _ in 0..<1_500 {
            await read(reader, plan(&rng))
            clock.now.addTimeInterval([0, 1, StreamHosts.rememberSeconds - 1, StreamHosts.rememberSeconds * 2].randomElement(using: &rng)!)
        }
    }

    func testEveryCombinationOnceAgainstAMemoryThatHasSeenEveryKindOfFailure() async {
        var rng = Seeded(22)
        let list = hosts()
        let reader = fetcher(list)
        for _ in 0..<100 {
            await read(reader, plan(&rng))
            clock.now.addTimeInterval(10)
        }
        let outcomes = Chaos.Outcome.allCases
        for a in outcomes {
            for b in outcomes {
                for c in outcomes {
                    await read(reader, [named: a, others[0]: b, others[1]: c])
                    clock.now.addTimeInterval(1)
                }
            }
        }
    }

    func testTheDayOfTheLogAServerThatIsDownAndOthersWhoseMadeUpNamesAreNoHosts() async {
        var rng = Seeded(23)
        let list = hosts()
        let reader = fetcher(list)
        for _ in 0..<800 {
            let own: Chaos.Outcome = Int.random(in: 0..<3, using: &rng) == 0 ? .ok : .connectTimeout
            await read(reader, [named: own, others[0]: .noAddress, others[1]: .noAddress])
            clock.now.addTimeInterval(Double(Int.random(in: 0..<90_000, using: &rng)) / 1_000)
        }
    }

    func testASubstituteThatIsRefusedForeverDoesNotKeepTheNamedServerFromBeingRead() async {
        let list = hosts()
        let reader = fetcher(list)
        // First the named server is down, so the others are put first; then it is back, and the others refuse
        await read(reader, [named: .connectTimeout, others[0]: .http403, others[1]: .tlsBroken])
        for _ in 0..<30 {
            for refusal in [Chaos.Outcome.http403, .http404, .http500, .reset, .tlsBroken, .noAddress] {
                await read(reader, [named: .ok, others[0]: refusal, others[1]: refusal])
            }
            clock.now.addTimeInterval(1)
        }
    }

    func testManyReadsAtOnceKeepToTheSameRules() async {
        var rng = Seeded(24)
        let list = hosts()
        let reader = fetcher(list)
        for _ in 0..<20 {
            // One table for the phase: the reads in it run together and share what the memory learns
            let outcomes = plan(&rng)
            Chaos.set(outcomes)
            let own = outcomes[named]!
            let someoneServes = outcomes.values.contains(.ok)
            let address = address()
            let results = await withTaskGroup(of: (Data?, Error?).self) { group -> [(Data?, Error?)] in
                for _ in 0..<40 {
                    group.addTask {
                        do { return (try await reader.bytes(address, range: 0...9, headers: [:]), nil) } catch { return (nil, error) }
                    }
                }
                var all: [(Data?, Error?)] = []
                for await result in group { all.append(result) }
                return all
            }
            for (data, failure) in results {
                if own == .ok || (own.isConnect && someoneServes) {
                    XCTAssertNotNil(data, "\(outcomes) \(String(describing: failure))")
                } else if data == nil {
                    // The named server's own failure, never a substitute's
                    if let code = own.error {
                        XCTAssertEqual((failure as? URLError)?.code, code, "\(outcomes)")
                    } else {
                        XCTAssertEqual((failure as? HTTPFailure)?.status, own.status, "\(outcomes)")
                    }
                }
            }
            clock.now.addTimeInterval(StreamHosts.rememberSeconds)
        }
    }

    func testAReadThatIsCancelledIsNeverAnsweredWithTheFailureOfAServer() async {
        Chaos.set([named: .connectTimeout, others[0]: .ok, others[1]: .ok])
        let reader = fetcher(hosts())
        let address = address()
        let task = Task { try await reader.bytes(address, range: 0...9, headers: [:]) }
        task.cancel()
        // Either it got there first and read, or it stopped: it does not throw something that is not a cancellation
        do { _ = try await task.value } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, "\(error)")
        }
    }

    // ------------------------------------------------------------------ the names

    func testWhateverTheAddressTheNamesMadeUpAreRealNamesAndTheNamedServerIsNeverLeftOut() {
        let names = ["sn-aaa", "sn-bbb", "sn-ccc", "sn-ddd-eee", "sn-42u-i5oss", "sn-oguelnsr", "sn-i3b7knse", "sn-ajoguc-5f"]
        var rng = Seeded(25)
        let list = StreamHosts(now: { Date(timeIntervalSince1970: 0) })
        for _ in 0..<8_000 {
            let letters = String(repeating: "r", count: Int.random(in: 1...2, using: &rng))
            let number = Int.random(in: 1..<40, using: &rng)
            let own = names.randomElement(using: &rng)!
            var listed = (0..<Int.random(in: 0..<5, using: &rng)).map { _ in names.randomElement(using: &rng)! }
            if Bool.random(using: &rng) { listed.insert(own, at: 0) } else { listed.append(own) }
            let domain = Int.random(in: 0..<8, using: &rng) == 0 ? "example.com" : "googlevideo.com"
            guard let url = URL(string: "https://\(letters)\(number)---\(own).\(domain)/videoplayback?a=1&mn=\(listed.joined(separator: ","))&sig=x") else {
                XCTFail("bad test address"); continue
            }
            if Int.random(in: 0..<3, using: &rng) == 0, let other = URL(string: "https://\(letters)1---\(names.randomElement(using: &rng)!).googlevideo.com/x") {
                list.markUnreachable(other)
            }
            let candidates = list.candidates(for: url)
            XCTAssertTrue(candidates.allSatisfy { $0.path == url.path && $0.query == url.query && $0.scheme == url.scheme }, url.absoluteString)
            XCTAssertTrue(candidates.contains { $0.host == url.host }, "\(url) -> \(candidates)")
            XCTAssertEqual(candidates.count, Set(candidates.compactMap(\.host)).count, "\(url) -> \(candidates)")
            for c in candidates where c.host != url.host {
                let host = c.host ?? ""
                XCTAssertNotNil(host.range(of: #"^r+1---sn-[a-z0-9-]+\.googlevideo\.com$"#, options: .regularExpression), host)
                let server = host.components(separatedBy: "---")[1].replacingOccurrences(of: ".googlevideo.com", with: "")
                XCTAssertTrue(listed.contains(server), "\(url) -> \(c)")
            }
            if domain != "googlevideo.com" { XCTAssertEqual(candidates, [url]) }
        }
    }

    func testAddressesThatAreNotStreamsAreLeftAloneAndNeverCrash() {
        let list = StreamHosts()
        for text in ["https://music.youtube.com/youtubei/v1/player?mn=sn-a,sn-b",
                     "https://redirector.googlevideo.com/videoplayback?mn=sn-a,sn-b",
                     "https://rr1.sn-aaa.googlevideo.com/videoplayback?mn=sn-aaa,sn-bbb",
                     "https://rrx---sn-aaa.googlevideo.com/videoplayback?mn=sn-aaa,sn-bbb",
                     "https://rr---sn-aaa.googlevideo.com/videoplayback?mn=sn-aaa,sn-bbb",
                     "https://rr1---xx-aaa.googlevideo.com/videoplayback?mn=xx-aaa,sn-bbb",
                     "https://rr1---sn-AAA.googlevideo.com/videoplayback?mn=sn-AAA,sn-bbb",
                     "https://rr1---sn-aaa.googlevideo.com/videoplayback",
                     "https://rr1---sn-aaa.googlevideo.com/videoplayback?mn=",
                     "https://rr1---sn-aaa.googlevideo.com/videoplayback?mn=,,",
                     "http://localhost:8080/a?mn=sn-a,sn-b"] {
            XCTAssertEqual(list.candidates(for: URL(string: text)!).count, 1, text)
        }
    }
}
