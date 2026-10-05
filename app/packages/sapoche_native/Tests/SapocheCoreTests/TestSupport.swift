import Foundation
import XCTest
@testable import SapocheCore

/// Time that only moves when a test says so. Waiting for it ends when the test moves past the moment.
final class VirtualTime: TimeSource {
    private struct Timer {
        let at: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var now: Int64 = 0
    private var timers: [Int: Timer] = [:]
    private var nextId = 0

    func nowMs() -> Int64 { now }

    func sleep(ms: Int64) async throws {
        try Task.checkCancellation()
        if ms <= 0 { return }
        let id = nextId
        nextId += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                timers[id] = Timer(at: now + ms, continuation: continuation)
                if Task.isCancelled, let timer = timers.removeValue(forKey: id) {
                    timer.continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let timer = self?.timers.removeValue(forKey: id) {
                    timer.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    /// Lets everything that is ready to run, run. Everything of the engine is on the main actor, so yielding is enough.
    func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Moves time forward by [ms], running whatever is due on the way in the order it is due.
    func advance(_ ms: Int64) async {
        let target = now + ms
        await settle()
        while let next = timers.filter({ $0.value.at <= target }).min(by: { ($0.value.at, $0.key) < ($1.value.at, $1.key) }) {
            now = max(now, next.value.at)
            timers[next.key] = nil
            next.value.continuation.resume()
            await settle()
        }
        now = target
        await settle()
    }
}

/// A player whose position advances with virtual time, so timing can be asserted to the millisecond.
final class FakePlayer: PlayerEngine {
    var loaded: QueueItem?
    var position: Int64 = 0
    var playing = false
    var currentSpeed: Float = 1
    var playedAtLocal: Int64?
    var prepareCount = 0
    var prepareDelayMs: Int64 = 0
    var failPrepare = false
    /// What loading an item throws, when it fails in a particular way; nil lets it load.
    var failWith: ((QueueItem) -> Error?)?
    var seeks: [Int64] = []
    var refreshed: [String] = []
    var queuedNext: QueueItem?

    var onEnded: (() -> Void)?
    var onAdvanced: (() -> Void)?
    var onError: ((Error) -> Void)?

    /// Sound only starts moving this long after play(), like real audio output latency.
    var startLatencyMs: Int64 = 0
    private var holdUntil: Int64 = 0
    private let time: VirtualTime
    private lazy var lastUpdate = time.now

    init(time: VirtualTime) {
        self.time = time
    }

    private func advance() {
        let t = time.now
        if playing {
            let from = max(lastUpdate, holdUntil)
            if t > from { position += Int64(Float(t - from) * currentSpeed) }
        }
        lastUpdate = t
    }

    func refresh(_ videoId: String) async {
        refreshed.append(videoId)
    }

    func prepare(_ item: QueueItem, seekToMs: Int64) async throws {
        try await time.sleep(ms: prepareDelayMs)
        if failPrepare { throw NSError(domain: "FakePlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot load"]) }
        if let error = failWith?(item) { throw error }
        prepareCount += 1
        advance()
        loaded = item
        queuedNext = nil
        position = seekToMs
        playing = false
    }

    func seekTo(_ positionMs: Int64) async throws {
        advance()
        position = positionMs
        seeks.append(positionMs)
    }

    func play() {
        advance()
        playing = true
        playedAtLocal = time.now
        holdUntil = time.now + startLatencyMs
    }

    func pause() {
        advance()
        playing = false
    }

    func stop() {
        advance()
        playing = false
        loaded = nil
    }

    func setSpeed(_ speed: Float) {
        advance()
        currentSpeed = speed
    }

    func setNext(_ item: QueueItem?) {
        if loaded != nil { queuedNext = item }
    }

    /// Test hook: the current item ran out and the queued next one started by itself.
    func autoAdvance() {
        advance()
        guard let successor = queuedNext else { return }
        loaded = successor
        queuedNext = nil
        position = 0
        onAdvanced?()
    }

    func positionMs() -> Int64 {
        advance()
        return position
    }

    func isPlaying() -> Bool { playing }

    // ---- what the controller asks of an engine

    var onChange: (() -> Void)?
    var onSongEndPause: (() -> Void)?
    var volume: Float = 1
    var pauseAtSongEnd = false
    var resumedLocally = 0

    var loadedItem: QueueItem? { loaded }
    var wantsSound: Bool { playing }

    func playerInfo() -> PlayerInfo {
        PlayerInfo(playing: playing, buffering: false, positionMs: positionMs(), durationMs: loaded?.durMs ?? 0)
    }

    func resumeLocally() {
        resumedLocally += 1
        play()
    }

    func setVolume(_ volume: Float) { self.volume = volume }

    func setPauseAtSongEnd(_ on: Bool) { pauseAtSongEnd = on }

    /// Test hook: shove the position, as if the device drifted.
    func nudge(_ deltaMs: Int64) {
        advance()
        position += deltaMs
    }
}

/// Fixtures shared by the tests.
func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no fixture \(name)"])
    }
    return try Data(contentsOf: url)
}
