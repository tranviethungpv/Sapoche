import XCTest
@testable import SapocheCore

final class NetworkHealthTests: XCTestCase {
    func testTheFirstStallMakesAGoodNetworkWeak() {
        let health = NetworkHealth()
        XCTAssertFalse(health.weak)
        XCTAssertTrue(health.onStall(10_000))
        XCTAssertTrue(health.weak)
        XCTAssertFalse(health.onStall(12_000))
    }

    func testWeakEndsAfterAQuietMinuteWithAFullBufferNotBefore() {
        let health = NetworkHealth()
        _ = health.onStall(10_000)
        XCTAssertFalse(health.tick(69_000, aheadMs: 40_000, fullyLoaded: false))
        XCTAssertFalse(health.tick(71_000, aheadMs: 10_000, fullyLoaded: false))
        XCTAssertTrue(health.tick(71_000, aheadMs: 10_000, fullyLoaded: true))
        XCTAssertFalse(health.weak)
    }

    func testBehindTheRoomTheWayToCatchUpDependsOnTheLagAndTheBuffer() {
        let health = NetworkHealth()
        XCTAssertEqual(health.catchUp(lagMs: 16_000, aheadMs: 60_000), .jump)
        XCTAssertEqual(health.catchUp(lagMs: 5_000, aheadMs: 15_000), .seekInBuffer)
        XCTAssertEqual(health.catchUp(lagMs: 1_000, aheadMs: 11_000), .seekInBuffer)
        XCTAssertEqual(health.catchUp(lagMs: 1_000, aheadMs: 20_000), .speed(1.03))
        XCTAssertEqual(health.catchUp(lagMs: 5_000, aheadMs: 8_000), .wait)
        XCTAssertEqual(health.catchUp(lagMs: 1_000, aheadMs: 5_000), .wait)
    }

    func testAMissedJumpCountsAsAStallSoWeakLastsAQuietMinuteFromIt() {
        let health = NetworkHealth()
        health.onJumpMissed(10_000, 4_000)
        XCTAssertTrue(health.weak)
        XCTAssertFalse(health.tick(20_000, aheadMs: 60_000, fullyLoaded: true))
        XCTAssertTrue(health.tick(71_000, aheadMs: 60_000, fullyLoaded: true))
    }

    func testTheTimeAskedForAJumpFollowsWhatLoadingTookWithinLimits() {
        let health = NetworkHealth()
        XCTAssertEqual(health.loadMs, 3_000)
        health.onJumpMissed(1_000, 4_000)
        XCTAssertEqual(health.loadMs, 8_000)
        health.onJumpMissed(2_000, 9_000)
        XCTAssertEqual(health.loadMs, NetworkHealth.maxLoadMs)
        for _ in 0..<10 { health.learnLoad(200) }
        XCTAssertEqual(health.loadMs, NetworkHealth.minLoadMs)
    }
}
