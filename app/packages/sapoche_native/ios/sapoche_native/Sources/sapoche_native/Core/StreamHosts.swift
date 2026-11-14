import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where else the stream at an address can be read from, and which of those servers could not be reached lately.
///
/// A YouTube stream address names one server, `rr1---sn-aaa.googlevideo.com`, and lists in `mn=sn-aaa,sn-bbb` the servers
/// that hold the same file: the signature does not cover the name of the server, so the same path on the second one gives
/// the same bytes (read 2026-11-14: a range of three songs answered 206 from either). When the first cannot be connected
/// to, which on some networks happens to one cache server of the provider and not to another, the second can be.
/// Mirrors `StreamHosts.kt`.
final class StreamHosts: @unchecked Sendable {
    /// Long enough for the songs of one sitting to skip a server that is down; short enough to try it again.
    static let rememberSeconds: TimeInterval = 5 * 60

    static let shared = StreamHosts()

    private let now: () -> Date
    private let remember: TimeInterval
    /// Only servers under this name are looked at; anything else is not a stream server.
    private let domain: String
    private let lock = NSLock()
    /// Server name to the time until which it is not tried first.
    private var unreachable: [String: Date] = [:]
    private var onEvent: @Sendable (String) -> Void = { _ in }

    init(now: @escaping () -> Date = Date.init, remember: TimeInterval = StreamHosts.rememberSeconds, domain: String = ".googlevideo.com") {
        self.now = now
        self.remember = remember
        self.domain = domain
    }

    /// Told when a server could not be connected to, and where the read goes on. Set once by the app, to its log.
    func setLog(_ log: @escaping @Sendable (String) -> Void) {
        lock.lock()
        onEvent = log
        lock.unlock()
    }

    func tell(_ line: String) {
        lock.lock()
        let log = onEvent
        lock.unlock()
        log(line)
    }

    /// The addresses to read [url] from, the one to try first first: the servers that were fine, in the order the address
    /// lists them, then the ones that could not be reached lately. One address when it names no other server.
    func candidates(for url: URL) -> [URL] {
        guard let host = url.host?.lowercased(), host.hasSuffix(domain),
              let (prefix, own) = Self.split(String(host.dropLast(domain.count))),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let list = parts.queryItems?.first(where: { $0.name == "mn" })?.value else { return [url] }
        let listed = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard listed.contains(own) else { return [url] }
        var servers = [own]
        for server in listed where !servers.contains(server) { servers.append(server) }
        let addresses = servers.compactMap { server -> URL? in
            parts.host = prefix + server + domain
            return parts.url
        }
        guard addresses.count == servers.count else { return [url] }
        let fine = addresses.filter { !isUnreachable($0) }
        return fine + addresses.filter { isUnreachable($0) }
    }

    /// The address to read [address] from first, as it is written: the same one when no other server is better.
    func preferred(_ address: String) -> String {
        guard let url = URL(string: address), let first = candidates(for: url).first, first != url else { return address }
        return first.absoluteString
    }

    /// [url]'s server could not be connected to: it is not tried first for a while.
    func markUnreachable(_ url: URL) {
        guard let host = url.host?.lowercased() else { return }
        lock.lock()
        unreachable[host] = now().addingTimeInterval(remember)
        lock.unlock()
    }

    private func isUnreachable(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let until = unreachable[host] else { return false }
        if now() < until { return true }
        unreachable[host] = nil
        return false
    }

    /// `rr1---sn-aaa` as the prefix `rr1---` and the name of the server `sn-aaa`, which the `mn` list repeats.
    private static func split(_ label: String) -> (String, String)? {
        guard let dashes = label.range(of: "---") else { return nil }
        let prefix = label[..<dashes.upperBound].dropLast(3)
        let server = label[dashes.upperBound...]
        guard prefix.first == "r", prefix.allSatisfy({ $0 == "r" || $0.isASCII && $0.isNumber }), prefix.last?.isNumber == true,
              server.hasPrefix("sn-"), server.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else { return nil }
        return (String(label[..<dashes.upperBound]), String(server))
    }

    /// The server could not be connected to (refused, or no answer to the first packet), as opposed to one that answered
    /// badly or stopped halfway, which another server will not mend. A timeout after some bytes arrived is the second kind.
    static func isConnectFailure(_ error: Error, receivedNothing: Bool) -> Bool {
        guard receivedNothing, let failure = error as? URLError else { return false }
        return failure.code == .cannotConnectToHost || failure.code == .timedOut
    }
}
