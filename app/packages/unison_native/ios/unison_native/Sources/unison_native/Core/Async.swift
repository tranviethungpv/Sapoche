import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Small stand-ins for what the Android side gets from Kotlin coroutines: a clock that tests can drive, jobs that
// can be cancelled together, and observable values. Everything that uses them runs on the main thread.

/// Time as the engine sees it: a monotonic clock that goes on counting while the device sleeps, and a way to wait.
@MainActor
protocol TimeSource: AnyObject {
    func nowMs() -> Int64
    func sleep(ms: Int64) async throws
}

enum Mono {
    /// Milliseconds on a clock that is not set by anybody and does not stop while the device sleeps.
    static func nowMs() -> Int64 {
        #if canImport(Darwin)
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        let ticks = mach_continuous_time()
        return Int64(ticks &* UInt64(base.numer) / UInt64(base.denom) / 1_000_000)
        #else
        var spec = timespec()
        clock_gettime(CLOCK_BOOTTIME, &spec)
        return Int64(spec.tv_sec) * 1000 + Int64(spec.tv_nsec) / 1_000_000
        #endif
    }
}

final class SystemTime: TimeSource {
    static let shared = SystemTime()

    func nowMs() -> Int64 { Mono.nowMs() }

    func sleep(ms: Int64) async throws {
        if ms > 0 {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        } else {
            try Task.checkCancellation()
        }
    }
}

/// Work started in a [Scope]. Cancelling it ends the waits inside it; it does not undo what it already did.
@MainActor
final class Job {
    fileprivate var task: Task<Void, Never>?
    fileprivate(set) var finished = false
    private(set) var cancelled = false

    var isActive: Bool { !finished && !cancelled }

    func cancel() {
        cancelled = true
        task?.cancel()
    }

    /// Returns once the work ended, by finishing or by being cancelled.
    func join() async {
        await task?.value
    }
}

/// Runs jobs on the main thread and cancels them all together.
@MainActor
final class Scope {
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var subscriptions: [Subscription] = []
    private(set) var isActive = true

    /// Starts [body]. Being cancelled ends it quietly; any other error goes to [onError] (or is dropped).
    @discardableResult
    func launch(onError: ((Error) -> Void)? = nil, _ body: @escaping @MainActor () async throws -> Void) -> Job {
        let job = Job()
        guard isActive else {
            job.cancel()
            return job
        }
        jobs[ObjectIdentifier(job)] = job
        job.task = Task { @MainActor [weak self] in
            if !job.cancelled {
                do {
                    try await body()
                } catch is CancellationError {
                    // Ended on purpose
                } catch {
                    onError?(error)
                }
            }
            job.finished = true
            self?.jobs[ObjectIdentifier(job)] = nil
        }
        return job
    }

    /// Calls [action] with the value now and after every change, until the scope is cancelled.
    func collect<T: Equatable>(_ flow: StateFlow<T>, _ action: @escaping (T) -> Void) {
        guard isActive else { return }
        subscriptions.append(flow.observe(action))
    }

    func collect<T>(_ flow: SharedFlow<T>, _ action: @escaping (T) -> Void) {
        guard isActive else { return }
        subscriptions.append(flow.observe(action))
    }

    func cancel() {
        isActive = false
        jobs.values.forEach { $0.cancel() }
        jobs.removeAll()
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
    }
}

/// Ends one observation of a flow.
@MainActor
final class Subscription {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func cancel() {
        action?()
        action = nil
    }
}

/// A value that others can watch; a change to an equal value is not announced.
@MainActor
final class StateFlow<T: Equatable> {
    private(set) var value: T
    private var observers: [Int: (T) -> Void] = [:]
    private var nextId = 0

    init(_ value: T) {
        self.value = value
    }

    func set(_ new: T) {
        guard new != value else { return }
        value = new
        for observer in observers.values { observer(new) }
    }

    func update(_ change: (inout T) -> Void) {
        var copy = value
        change(&copy)
        set(copy)
    }

    /// Reports the value now and every change after it.
    func observe(_ observer: @escaping (T) -> Void) -> Subscription {
        let id = nextId
        nextId += 1
        observers[id] = observer
        observer(value)
        return Subscription { [weak self] in self?.observers[id] = nil }
    }
}

/// Things that happened, for whoever is listening at that moment.
@MainActor
final class SharedFlow<T> {
    private var observers: [Int: (T) -> Void] = [:]
    private var nextId = 0

    func emit(_ value: T) {
        for observer in observers.values { observer(value) }
    }

    func observe(_ observer: @escaping (T) -> Void) -> Subscription {
        let id = nextId
        nextId += 1
        observers[id] = observer
        return Subscription { [weak self] in self?.observers[id] = nil }
    }
}

@MainActor
extension TimeSource {
    /// Waits [ms]; false when the wait was cut short by cancellation.
    func wait(ms: Int64) async -> Bool {
        do {
            try await sleep(ms: ms)
            return true
        } catch {
            return false
        }
    }
}

/// Raised in place of a wait that took too long.
struct TimedOut: Error {}

/// Gives the answer of [work], or throws [TimedOut] when it takes longer than [ms].
@MainActor
func withTimeout<T>(ms: Int64, time: TimeSource? = nil, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
    let time = time ?? SystemTime.shared
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { @MainActor in try await work() }
        group.addTask { @MainActor in
            try await time.sleep(ms: ms)
            throw TimedOut()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Lets one caller at a time through a stretch of async code, in the order they came, even though the code waits in
/// the middle (an actor alone would let another caller in at the first wait).
final class AsyncMutex: @unchecked Sendable {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        while busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await body()
    }
}
