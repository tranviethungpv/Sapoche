import Foundation

/// What a device that fell behind the room does about it while its network is weak, see [NetworkHealth.catchUp].
enum CatchUp: Equatable {
    /// Keep playing at normal speed: the data to go faster is not there.
    case wait
    /// Close the gap by speeding up a little: it is small and the buffer can pay for it.
    case speed(Float)
    /// One seek to where the room is: the buffer holds that place.
    case seekInBuffer
    /// Too far behind to wait for: pause, load the room's place, and start there at an agreed moment.
    case jump
}

/// Tells a network that is slow or comes and goes from a good one, from the stalls a player reports, and keeps what the
/// session learned about it. Pure logic on the caller's monotonic clock; one per session (`GroupSession`, `LocalSession`).
///
/// A good network never gets here: the first stall that is not the player's own doing turns `weak` on, and a minute without
/// another one, with a full buffer ahead, turns it off.
final class NetworkHealth {
    private(set) var weak = false {
        didSet { if weak != oldValue { onChange?(weak) } }
    }

    /// Called when `weak` turns on or off.
    var onChange: ((Bool) -> Void)?

    /// How long loading a place the player does not have takes, learned from jumps and loads. Aims the next start.
    private(set) var loadMs = NetworkHealth.defaultLoadMs

    private var lastStallEndMs: Int64 = 0

    /// The player stalled, and played again at [nowMs]. Returns true when this is what turned weak mode on.
    func onStall(_ nowMs: Int64) -> Bool {
        lastStallEndMs = nowMs
        let turned = !weak
        weak = true
        return turned
    }

    /// A jump to a place the player had to load took [tookMs] against the lead it was given.
    func learnLoad(_ tookMs: Int64) {
        loadMs = min(max(Int64((Double(loadMs) + Double(tookMs) * Self.loadMargin) / 2), Self.minLoadMs), Self.maxLoadMs)
    }

    /// A jump did not make its moment at [nowMs]: ask for more time next, and count it as a stall for how long the network stays weak.
    func onJumpMissed(_ nowMs: Int64, _ tookMs: Int64) {
        lastStallEndMs = nowMs
        weak = true
        loadMs = min(max(max(loadMs, tookMs) * 2, Self.minLoadMs), Self.maxLoadMs)
    }

    /// Whether [nowMs] is late enough in a calm spell, with [aheadMs] of song buffered, to go back to the plain rules.
    func tick(_ nowMs: Int64, aheadMs: Int64, fullyLoaded: Bool) -> Bool {
        if !weak { return false }
        if nowMs - lastStallEndMs < Self.quietMs { return false }
        if aheadMs < Self.recoveredAheadMs && !fullyLoaded { return false }
        weak = false
        loadMs = Self.defaultLoadMs
        return true
    }

    /// How a device [lagMs] behind the room (positive) catches up while the network is weak, with [aheadMs] of the song
    /// already loaded ahead of its position.
    func catchUp(lagMs: Int64, aheadMs: Int64) -> CatchUp {
        if lagMs > Self.maxLagMs { return .jump }
        if lagMs < Self.speedLagMs && aheadMs >= Self.speedAheadMs { return .speed(1.03) }
        if aheadMs >= lagMs + Self.seekBufferMs { return .seekInBuffer }
        return .wait
    }

    static let defaultLoadMs: Int64 = 3_000
    static let minLoadMs: Int64 = 2_000
    static let maxLoadMs: Int64 = 10_000
    private static let loadMargin = 1.5

    /// No stall for this long, and a buffer of `recoveredAheadMs`, and the network counts as good again.
    static let quietMs: Int64 = 60_000
    static let recoveredAheadMs: Int64 = 30_000

    /// A device may run this far behind the room before it jumps, rather than stall again to close the gap.
    static let maxLagMs: Int64 = 15_000
    static let seekBufferMs: Int64 = 10_000
    static let speedLagMs: Int64 = 1_500
    static let speedAheadMs: Int64 = 20_000

    /// At most one seek this often while weak; a seek that is followed by a stall doubles it.
    static let seekGapMs: Int64 = 20_000
}
