import XCTest
@testable import SapocheCore

final class CanSteerTests: XCTestCase {
    private func snapshot(guestControl: String = "all", ownerId: String? = "owner", you: String? = "guest",
                          ownerAway: Bool = false, solo: Bool = false) -> GroupSession.Snapshot {
        var snapshot = GroupSession.Snapshot()
        snapshot.state = RoomState(queue: [], index: 0, phase: "idle", startedAt: 0, positionMs: 0, epoch: 1,
                                   ownerId: ownerId, guestControl: guestControl)
        snapshot.members = [Member(id: "owner", name: "Owner", ready: true, away: ownerAway, owner: true),
                            Member(id: "guest", name: "Guest", ready: true)]
        snapshot.you = you
        snapshot.solo = solo
        return snapshot
    }

    func testOutsideARoomEverythingIsAllowed() {
        XCTAssertTrue(GroupSession.Snapshot().canSteer)
    }

    func testAGuestMaySteerWhenGuestsAreFree() {
        XCTAssertTrue(snapshot(guestControl: "all").canSteer)
    }

    func testAGuestMayNotSteerWhileTheOwnerIsHereAndGuestsOnlyAdd() {
        XCTAssertFalse(snapshot(guestControl: "add").canSteer)
    }

    func testTheOwnerAlwaysMaySteer() {
        XCTAssertTrue(snapshot(guestControl: "add", you: "owner").canSteer)
    }

    func testAGuestMaySteerOnceTheOwnerIsAway() {
        XCTAssertTrue(snapshot(guestControl: "add", ownerAway: true).canSteer)
    }

    func testListeningAloneIsNotTheRoomsToRefuse() {
        XCTAssertTrue(snapshot(guestControl: "add", solo: true).canSteer)
    }
}
