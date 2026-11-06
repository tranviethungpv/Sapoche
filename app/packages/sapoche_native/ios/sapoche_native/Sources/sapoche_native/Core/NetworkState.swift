import Foundation

/// What the whole app knows of the network, for code that has no session to ask: the stream cache picks a lower quality
/// by it. Written by `NetworkHealth` (weak) and by the player (what it measured); read from any thread.
final class NetworkState: @unchecked Sendable {
    static let shared = NetworkState()

    private let lock = NSLock()
    private var weakValue = false
    private var bandwidthValue: Int64 = 0

    /// The network is too weak for the plain rules: songs are fetched in a lower quality.
    var weak: Bool {
        get { lock.withLock { weakValue } }
        set { lock.withLock { weakValue = newValue } }
    }

    /// What the player last measured the network to carry, in kbps; 0 until it measured.
    var bandwidthKbps: Int64 {
        get { lock.withLock { bandwidthValue } }
        set { lock.withLock { bandwidthValue = newValue } }
    }
}
