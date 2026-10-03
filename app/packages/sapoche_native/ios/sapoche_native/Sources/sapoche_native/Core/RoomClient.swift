import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// [refused]: the server turned this device away for good (room full, no such room, removed by the owner).
enum Connection: Equatable {
    case connecting, connected, reconnecting, closed, unauthorized, refused
}

/// A value that arrives later, once; whoever waits for it is resumed.
@MainActor
final class Deferred<T> {
    private var value: T?
    private var waiting: CheckedContinuation<T, Never>?

    func complete(_ result: T) {
        guard value == nil else { return }
        value = result
        waiting?.resume(returning: result)
        waiting = nil
    }

    func get() async -> T {
        if let value { return value }
        return await withCheckedContinuation { continuation in
            if let value {
                continuation.resume(returning: value)
            } else {
                waiting = continuation
            }
        }
    }
}

/// What the socket reports about itself while it is open, closed or failed.
@MainActor
protocol SocketEvents: AnyObject {
    func socketOpened()
    func socketMessage(_ text: String)
    func socketEnded(code: Int, reason: String)
    func socketFailed(_ error: Error, httpStatus: Int?)
}

/// Opens a WebSocket and reports what happens to it on the main thread.
@MainActor
protocol SocketFactory {
    func open(url: URL, headers: [String: String], events: SocketEvents) -> Socket
}

@MainActor
protocol Socket: AnyObject {
    @discardableResult func send(_ text: String) -> Bool
    func cancel()
    func close(code: Int, reason: String)
}

/// WebSocket connection to one room. Joins on every (re)connect, keeps the clock offset fresh with pings, and
/// reconnects with exponential backoff when the connection drops. Runs on the main thread.
@MainActor
final class RoomClient: SocketEvents {
    var onMessage: (ServerMessage) -> Void = { _ in }

    /// Called after each successful (re)connect, once the join message was sent.
    var onConnected: () -> Void = {}

    /// A member's picture arrived ([av] is its fingerprint), or with no [data] they took it away.
    var onAvatar: (_ id: String, _ av: String?, _ data: String?) -> Void = { _, _, _ in }

    let connection = StateFlow<Connection>(.connecting)

    private let url: URL
    private let clientId: String
    private let scope: Scope
    private let clock: ClockSync
    private let time: TimeSource
    private let log: (String) -> Void
    private let headers: [String: String]
    private let sockets: SocketFactory

    /// How often to ping once connected, and how long silence may last before the connection is dropped.
    private let pingEveryMs: Int64
    private let pongDeadlineMs: Int64

    private var socket: Socket?
    private var loop: Job?
    private var pinger: Job?

    /// What this device expects of the room, see [Wire.join]. It is sent until the server has answered once; after
    /// that a reconnect must not open a new room if the old one expired.
    private var createOnJoin: Bool?

    /// When the server last answered a ping, on the [time] clock.
    private var lastPongMs: Int64 = 0

    /// Where the attempt in progress ends, with the close code (or -401 for a refused key, -1 for any failure).
    private var attemptEnd: Deferred<Int>?

    /// Failed attempts since the last time the connection was up; sets how long the next wait is.
    private var attempts = 0

    /// A token here ends the current reconnect wait early, or the next one if none is going on.
    private var wake: Deferred<Void>?
    private var wakeRequested = false

    /// Shown to the others; sent again on every reconnect.
    private(set) var name: String

    /// This device's own picture, as base64; shared with the room once the server says it can keep pictures.
    private var avatar: String?

    /// What the server last said it can do, and whether the picture went out on this connection.
    private var serverProtocol = 0
    private var avatarSent = false

    /// The fingerprint of each member's picture as last asked for, so a picture is fetched once and not at every change.
    private var known: [String: String] = [:]

    init(baseUrl: String, roomCode: String, clientId: String, name: String, scope: Scope, clock: ClockSync,
         time: TimeSource? = nil, log: @escaping (String) -> Void = { _ in }, headers: [String: String] = [:],
         create: Bool? = nil, sockets: SocketFactory? = nil, pingEveryMs: Int64 = RoomClient.refreshMs,
         pongDeadlineMs: Int64 = RoomClient.pongDeadlineMs) {
        var base = baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("http") { base = "ws" + base.dropFirst(4) }
        // Only what a room code is made of goes into the address, whatever was typed
        let code = String(roomCode.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        url = URL(string: base + "/room/" + code) ?? URL(string: "wss://invalid.invalid/")!
        self.clientId = clientId
        self.name = name
        self.scope = scope
        self.clock = clock
        self.time = time ?? SystemTime.shared
        self.log = log
        self.headers = headers
        self.sockets = sockets ?? URLSessionSockets()
        createOnJoin = create
        self.pingEveryMs = pingEveryMs
        self.pongDeadlineMs = pongDeadlineMs
    }

    func start() {
        if loop != nil { return }
        loop = scope.launch { [weak self] in await self?.connectLoop() }
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        socket?.send(text) ?? false
    }

    /// Sets, or with nil takes away, the picture the others see of this device. Sent again on every reconnect.
    func setAvatar(_ data: String?) {
        avatar = data
        if serverProtocol >= Self.avatarProtocol { send(Wire.avatarSet(data)) }
    }

    /// Changes the display name without dropping the connection: the server accepts a second join.
    func rename(_ newName: String) {
        name = newName
        send(Wire.join(clientId: clientId, name: newName))
    }

    /// The device's network changed or came back: do not wait out the backoff, and replace a connection that may be
    /// dead without knowing it.
    func reconnectNow() {
        if loop == nil { return }
        if connection.value == .connected {
            socket?.cancel()
            attemptEnd?.complete(-1)
        }
        wakeRequested = true
        wake?.complete(())
    }

    /// Leaves on purpose: tells the room, so an owner hands it over, then closes.
    func leave() {
        send(Wire.bye())
        close()
    }

    func close() {
        loop?.cancel()
        loop = nil
        pinger?.cancel()
        pinger = nil
        socket?.close(code: 1000, reason: "leaving")
        socket = nil
        attemptEnd?.complete(-2)
        wake?.complete(())
        connection.set(.closed)
    }

    private func connectLoop() async {
        attempts = 0
        while scope.isActive, loop != nil {
            connection.set(attempts == 0 ? .connecting : .reconnecting)
            let ended = Deferred<Int>()
            attemptEnd = ended
            let ws = sockets.open(url: url, headers: headers, events: self)
            socket = ws

            let code = await ended.get()
            pinger?.cancel()
            pinger = nil
            ws.cancel()
            if socket === ws { socket = nil }
            if loop == nil || Task.isCancelled { return }

            if code == Self.closeUnauthorized {
                // A wrong or missing key stays wrong; retrying only hammers the server
                log("the server rejected our key, giving up")
                connection.set(.unauthorized)
                return
            }
            if code == Self.closePolicyViolation || code == Self.closeRemoved || code == Self.closeNotFound {
                // The server refuses us (room full, removed by the owner, no such room); retrying would not help
                log("server refused the connection (\(code)), giving up")
                connection.set(.refused)
                return
            }
            let wait = backoffMs(attempts)
            attempts += 1
            if wakeRequested {
                // Asked to connect again at once, e.g. the network came back
                wakeRequested = false
                continue
            }
            log("reconnecting in \(wait)ms")
            let woken = Deferred<Void>()
            wake = woken
            let timer = scope.launch { [weak self] in
                guard await (self?.time.wait(ms: wait) ?? false) else { return }
                woken.complete(())
            }
            await woken.get()
            timer.cancel()
            wake = nil
            wakeRequested = false
        }
    }

    // ------------------------------------------------------------------ SocketEvents

    func socketOpened() {
        attempts = 0
        connection.set(.connected)
        log("connected to \(url)")
        lastPongMs = time.nowMs()
        avatarSent = false
        socket?.send(Wire.join(clientId: clientId, name: name, create: createOnJoin))
        pinger?.cancel()
        if let socket {
            pinger = scope.launch { [weak self] in await self?.pingLoop(socket) }
        }
        onConnected()
    }

    func socketMessage(_ text: String) {
        switch Wire.parse(text) {
        case nil:
            log("ignoring unparsable message")
        case let .pong(c0, s1):
            lastPongMs = time.nowMs()
            clock.addSample(c0: c0, c2: time.nowMs(), s1: s1)
        case let .avatar(id, av, data):
            known[id] = av
            onAvatar(id, av, data)
        case let message?:
            if case .state = message, createOnJoin == true { createOnJoin = false }
            if case let .state(_, _, _, members, protocolVersion) = message {
                serverProtocol = protocolVersion
                shareAvatar()
                wantPictures(members)
            } else if case let .members(members) = message {
                wantPictures(members)
            }
            onMessage(message)
        }
    }

    /// Hands the room this device's picture, once per connection, when the server can keep it.
    private func shareAvatar() {
        if avatarSent || serverProtocol < Self.avatarProtocol { return }
        avatarSent = true
        socket?.send(Wire.avatarSet(avatar))
    }

    /// Asks for the pictures of members whose picture changed since it was last fetched, and forgets those who are gone.
    private func wantPictures(_ members: [Member]) {
        if serverProtocol < Self.avatarProtocol { return }
        let present = Set(members.map(\.id))
        known = known.filter { present.contains($0.key) }
        for member in members where member.id != clientId {
            if let av = member.av {
                if known[member.id] != av {
                    known[member.id] = av
                    socket?.send(Wire.avatarGet(member.id))
                }
            } else if known.removeValue(forKey: member.id) != nil {
                // They had one and took it away
                onAvatar(member.id, nil, nil)
            }
        }
    }

    func socketEnded(code: Int, reason: String) {
        log("closed: \(code) \(reason)")
        // A close code the system does not pass on is told apart by the words the server gave
        var known = code
        if known != Self.closeRemoved && reason.contains("removed by the owner") { known = Self.closeRemoved }
        if known != Self.closeNotFound && reason.contains("room not found") { known = Self.closeNotFound }
        attemptEnd?.complete(known)
    }

    func socketFailed(_ error: Error, httpStatus: Int?) {
        log("connection failed: \(error.localizedDescription) (http \(httpStatus.map(String.init) ?? "-"))")
        attemptEnd?.complete(httpStatus == 401 ? Self.closeUnauthorized : -1)
    }

    /// A quick burst right after connecting for a good first estimate, then a slow refresh: each ping keeps the radio
    /// awake, and the server counts it as presence. A connection that stopped answering without saying so is dropped
    /// here, since nothing else would notice.
    private func pingLoop(_ ws: Socket) async {
        for _ in 0..<Self.burstPings {
            ws.send(Wire.ping(time.nowMs()))
            guard await time.wait(ms: Self.burstGapMs) else { return }
        }
        while true {
            guard await time.wait(ms: pingEveryMs) else { return }
            if time.nowMs() - lastPongMs > pongDeadlineMs {
                log("no answer to pings for \((time.nowMs() - lastPongMs) / 1000)s, dropping the connection")
                ws.cancel()
                attemptEnd?.complete(-1)
                return
            }
            ws.send(Wire.ping(time.nowMs()))
        }
    }

    private func backoffMs(_ attempt: Int) -> Int64 {
        min(15_000, Int64(1000) << Int64(min(max(attempt, 0), 4)))
    }

    /// The first protocol that keeps members' pictures.
    private static let avatarProtocol = 8
    private static let closePolicyViolation = 1008
    private static let closeRemoved = 4001
    private static let closeNotFound = 4004
    private static let closeUnauthorized = -401
    private static let burstPings = 8
    private static let burstGapMs: Int64 = 250
    nonisolated static let refreshMs: Int64 = 30_000

    /// A healthy connection answers every ping, one per [refreshMs]; a whole missed round means it is dead.
    nonisolated static let pongDeadlineMs: Int64 = 45_000
}

// ---------------------------------------------------------------------- URLSession

/// The sockets of the system's URLSession.
@MainActor
final class URLSessionSockets: SocketFactory {
    func open(url: URL, headers: [String: String], events: SocketEvents) -> Socket {
        let socket = URLSessionSocket(events: events)
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        socket.start(request)
        return socket
    }
}


/// The sockets of the system's URLSession.
@MainActor
final class URLSessionSocket: NSObject, Socket, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    private weak var events: SocketEvents?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var finished = false

    @MainActor
    init(events: SocketEvents) {
        self.events = events
    }

    @MainActor
    func start(_ request: URLRequest) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: OperationQueue.main)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        listen(task)
    }

    @MainActor
    @discardableResult
    func send(_ text: String) -> Bool {
        guard let task, !finished else { return false }
        task.send(.string(text)) { _ in }
        return true
    }

    @MainActor
    func cancel() {
        finished = true
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    @MainActor
    func close(code: Int, reason: String) {
        finished = true
        task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
        session?.finishTasksAndInvalidate()
    }

    @MainActor
    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                switch result {
                case let .success(.string(text)):
                    self.events?.socketMessage(text)
                    self.listen(task)
                case let .success(.data(data)):
                    if let text = String(data: data, encoding: .utf8) { self.events?.socketMessage(text) }
                    self.listen(task)
                case .success:
                    self.listen(task)
                case .failure:
                    break // the delegate reports how the socket ended
                }
            }
        }
    }

    // The delegate is called on the main queue, and each call goes on to the main actor in the order it came

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            self.events?.socketOpened()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let code = closeCode.rawValue
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.events?.socketEnded(code: code, reason: text)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            if let error {
                self.events?.socketFailed(error, httpStatus: status)
            } else {
                self.events?.socketEnded(code: -1, reason: "")
            }
        }
    }
}
