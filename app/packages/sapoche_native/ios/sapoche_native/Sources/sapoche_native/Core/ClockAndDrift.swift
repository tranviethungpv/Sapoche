import Foundation

/// Estimates the offset between this device's monotonic clock and the server clock, NTP style.
///
/// Each ping/pong exchange gives one sample: with c0 the local send time, s1 the server time in the reply and c2 the
/// local receive time, the round trip is c2 - c0 and the server clock read s1 at about local time c0 + rtt/2. The
/// error of one sample is bounded by half its round trip, and grows with its age because the two clocks do not tick
/// at exactly the same rate (phone crystals are off by tens of parts per million). The sample with the smallest bound
/// wins, as NTP does with its dispersion: a fast round trip from five minutes ago no longer beats a slightly slower
/// one from just now.
///
/// "Local" times must come from one monotonic clock; wall clock changes would corrupt the offset.
final class ClockSync {
    private struct Sample {
        let offsetMs: Double
        let rttMs: Double
        let atMs: Int64
    }

    /// How fast two clocks may drift apart: 100 parts per million, a phone crystal with margin.
    private static let driftPerMs = 100e-6

    private let windowSize: Int
    private var samples: [Sample] = []

    init(windowSize: Int = 12) {
        self.windowSize = windowSize
    }

    func addSample(c0: Int64, c2: Int64, s1: Int64) {
        let rtt = Double(c2 - c0)
        if rtt < 0 { return }
        samples.append(Sample(offsetMs: Double(s1) - (Double(c0) + rtt / 2), rttMs: rtt, atMs: c2))
        while samples.count > windowSize { samples.removeFirst() }
    }

    func hasSync() -> Bool { !samples.isEmpty }

    /// Server time minus local time, from the recent sample with the smallest error bound. 0 until the first sample.
    func offsetMs() -> Double {
        best()?.offsetMs ?? 0
    }

    /// Round trip of the sample the offset is based on, or nil before the first sample.
    func bestRttMs() -> Double? {
        best()?.rttMs
    }

    /// Half the round trip, plus what the clocks may have drifted apart since, counted up to the newest sample.
    private func best() -> Sample? {
        guard let newest = samples.last?.atMs else { return nil }
        func bound(_ sample: Sample) -> Double { sample.rttMs / 2 + Double(newest - sample.atMs) * ClockSync.driftPerMs }
        return samples.min(by: { bound($0) < bound($1) })
    }

    func toServer(_ localMs: Int64) -> Int64 { localMs + Int64(offsetMs()) }

    func toLocal(_ serverMs: Int64) -> Int64 { serverMs - Int64(offsetMs()) }
}

enum DriftAction: Equatable {
    /// Nothing to change.
    case none
    /// Change the playback speed; 1.0 restores normal playback.
    case setSpeed(Float)
    /// Too far off to correct smoothly: jump to the expected position.
    case seek
}

/// Decides how to pull a player back in line with the room.
///
/// Drift is player position minus expected position: positive means this device is ahead and must slow down,
/// negative means it is behind and must speed up. Small drift is corrected by nudging the speed (inaudible), large
/// drift by seeking. Correction stops when the drift is nearly gone, with a gap between the start and stop
/// thresholds so it does not flutter.
final class DriftController {
    private let deadbandMs: Int64
    private let settleMs: Int64
    let seekThresholdMs: Int64
    private let speedDelta: Float

    /// -1 while slowing down, +1 while speeding up, 0 at normal speed.
    private var correcting = 0

    init(deadbandMs: Int64 = 40, settleMs: Int64 = 15, seekThresholdMs: Int64 = 400, speedDelta: Float = 0.03) {
        self.deadbandMs = deadbandMs
        self.settleMs = settleMs
        self.seekThresholdMs = seekThresholdMs
        self.speedDelta = speedDelta
    }

    func decide(_ driftMs: Int64) -> DriftAction {
        let size = abs(driftMs)

        if size > seekThresholdMs {
            // The caller restores normal speed together with the seek
            correcting = 0
            return .seek
        }

        if correcting == 0 {
            if size <= deadbandMs { return .none }
            correcting = driftMs > 0 ? -1 : 1
            return .setSpeed(1 + Float(correcting) * speedDelta)
        }

        // Currently correcting: stop when close enough or when we overshot to the other side
        let overshot = (correcting == -1 && driftMs <= 0) || (correcting == 1 && driftMs >= 0)
        if size <= settleMs || overshot {
            correcting = 0
            return .setSpeed(1)
        }
        return .none
    }

    /// Forget any correction in progress, e.g. after the player was reset to normal speed.
    func reset() {
        correcting = 0
    }
}

/// Smooths the drift readings before they reach the [DriftController].
///
/// Player position readings are noisy: on the test phones raw drift showed a sawtooth of about 200ms with a 3-4
/// second period even with no correction at all. Acting on single readings would chase that noise, so the filter
/// averages a window of readings. Because a speed change moves the position on purpose, each reading is first
/// stripped of the correction applied so far; the average of those is the drift the device would have had without
/// any correction, and adding the current correction back gives its drift right now.
final class DriftFilter {
    private let size: Int
    private let minSamplesForLargeDrift: Int
    private var samples: [Double] = []

    /// Total shift, in ms, that speed changes have applied to the position.
    private var correctionMs = 0.0
    private var speed: Float = 1
    private var lastMs: Int64 = 0

    init(size: Int = 8, minSamplesForLargeDrift: Int = 3) {
        self.size = size
        self.minSamplesForLargeDrift = minSamplesForLargeDrift
    }

    var count: Int { samples.count }

    /// The window is full enough to trust for a small correction.
    var isFull: Bool { samples.count >= size }

    /// The window has enough readings to confirm a large drift.
    var hasLargeDriftEvidence: Bool { samples.count >= minSamplesForLargeDrift }

    private func advance(_ nowMs: Int64) {
        correctionMs += Double(speed - 1) * Double(nowMs - lastMs)
        lastMs = nowMs
    }

    func add(_ nowMs: Int64, _ driftMs: Int64) {
        advance(nowMs)
        samples.append(Double(driftMs) - correctionMs)
        if samples.count > size { samples.removeFirst() }
    }

    /// Mean drift the device would have without any correction, or nil with no readings.
    func uncorrectedMean() -> Double? {
        samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)
    }

    /// Best estimate of the drift at [nowMs], or nil when there are no readings.
    func estimate(_ nowMs: Int64) -> Int64? {
        guard let mean = uncorrectedMean() else { return nil }
        advance(nowMs)
        return Int64(mean + correctionMs)
    }

    /// Record a speed change so later readings are compensated correctly.
    func setSpeed(_ nowMs: Int64, _ newSpeed: Float) {
        advance(nowMs)
        speed = newSpeed
    }

    /// Forget everything, e.g. after a seek moved the position discontinuously.
    func reset(_ nowMs: Int64, speed newSpeed: Float = 1) {
        samples.removeAll()
        correctionMs = 0
        speed = newSpeed
        lastMs = nowMs
    }
}
