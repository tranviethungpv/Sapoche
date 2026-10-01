import Foundation

/// Small settings that outlive a run: the room this device was in, its name, what the person chose in the app.
protocol KeyValueStore: AnyObject {
    func string(_ key: String) -> String?
    func int64(_ key: String) -> Int64?
    func bool(_ key: String) -> Bool?
    func set(_ value: String?, for key: String)
    func set(_ value: Int64, for key: String)
    func set(_ value: Bool, for key: String)
    func remove(_ key: String)
}

extension KeyValueStore {
    func bool(_ key: String, default value: Bool) -> Bool { bool(key) ?? value }
    func int64(_ key: String, default value: Int64) -> Int64 { int64(key) ?? value }
}

/// Settings kept in memory only, for tests.
final class MemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]

    func string(_ key: String) -> String? { values[key] as? String }
    func int64(_ key: String) -> Int64? { values[key] as? Int64 }
    func bool(_ key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: String?, for key: String) { values[key] = value }
    func set(_ value: Int64, for key: String) { values[key] = value }
    func set(_ value: Bool, for key: String) { values[key] = value }
    func remove(_ key: String) { values[key] = nil }
}

/// A short diary of what the native side did, for the log screen. Kept in memory; the newest lines last.
final class EventLog: @unchecked Sendable {
    static let shared = EventLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 500

    static func d(_ tag: String, _ message: String) {
        shared.add(tag, message)
    }

    func add(_ tag: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        lines.append("\(stamp) \(tag): \(message)")
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Where the room server is and the key it asks for. Entered by the person on first use, so that no secret has to be
/// built into the app.
struct ServerConfig: Equatable {
    var server: String = ""
    var key: String = ""

    /// There is an address to talk to.
    var isSet: Bool { URL(string: server)?.host != nil }

    /// Headers that every call to the room server must carry.
    var authHeaders: [String: String] { key.isEmpty ? [:] : ["X-Unison-Key": key] }

    static func load(_ store: KeyValueStore) -> ServerConfig {
        ServerConfig(server: store.string("server_url") ?? "", key: store.string("server_key") ?? "")
    }

    func save(to store: KeyValueStore) {
        store.set(server, for: "server_url")
        store.set(key, for: "server_key")
    }

    /// A web address cleaned of spaces and a closing slash; an address without a scheme is taken to be https.
    static func clean(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.isEmpty && !text.contains("://") { text = "https://" + text }
        return text
    }
}

/// An error the UI shows as a message: a song that could not play, a queue that is full.
struct ControllerError: Equatable {
    let code: String
    let message: String
}
