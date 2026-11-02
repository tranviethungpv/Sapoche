import XCTest
@testable import SapocheCore

final class WidgetSnapshotTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let room = WidgetSnapshot(
        title: "STAY", artist: "The Kid LAROI", playing: true, room: "Weekend · 4", roomCode: "ABC123", crew: ["Lan", "Minh"],
        next: [.init(title: "Next", artist: "A", by: "Lan")], canSteer: false,
        startedAt: Date(timeIntervalSince1970: 1_000), endsAt: Date(timeIntervalSince1970: 1_200), updatedAt: Date(timeIntervalSince1970: 1_100)
    )

    func testASnapshotSurvivesTheFile() throws {
        let storage = WidgetStorage(folder: try folder())
        storage.write(room)
        XCTAssertEqual(storage.read(), room)
    }

    func testNothingWrittenIsNothingRead() throws {
        XCTAssertNil(WidgetStorage(folder: try folder()).read())
    }

    func testAFileThatIsNotASnapshotIsNothing() throws {
        let dir = try folder()
        try Data("not json".utf8).write(to: dir.appendingPathComponent(WidgetStorage.snapshotFile))
        XCTAssertNil(WidgetStorage(folder: dir).read())
    }

    func testOnlyTheFirstFewNextSongsAreKept() {
        let rows = (1...6).map { WidgetSnapshot.Row(title: "T\($0)", artist: "A") }
        XCTAssertEqual(WidgetSnapshot(title: "x", next: rows).next.map(\.title), ["T1", "T2", "T3"])
    }

    func testNothingLoadedIsIdle() {
        XCTAssertTrue(WidgetSnapshot().isIdle)
        XCTAssertFalse(room.isIdle)
    }

    func testTheTimeItWasWrittenAtIsNotWhatIsShown() {
        var later = room
        later.updatedAt = Date(timeIntervalSince1970: 9_999)
        XCTAssertEqual(room.shown, later.shown)
        later.playing = false
        XCTAssertNotEqual(room.shown, later.shown)
    }

    func testTheCoverIsKeptAndTakenAway() throws {
        let storage = WidgetStorage(folder: try folder())
        XCTAssertNil(storage.cover())
        storage.writeCover(Data([1, 2, 3]))
        XCTAssertEqual(storage.cover(), Data([1, 2, 3]))
        storage.writeCover(nil)
        XCTAssertNil(storage.cover())
    }
}
