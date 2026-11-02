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

    func testWhatTheAppKnowsOfFriendsAndPlaylistsSurvivesTheFile() throws {
        let storage = WidgetStorage(folder: try folder())
        var full = room
        full.friends = .init(code: "XYZ789", room: "Late night", who: ["Lan"], song: "STAY")
        full.playlist = .init(id: 7, name: "Gym")
        full.language = "vi"
        full.next = [.init(title: "Next", artist: "A", by: "Lan", id: "q1")]
        storage.write(full)
        XCTAssertEqual(storage.read(), full)
    }

    // ------------------------------------------------------------------ the shared folder's name

    private func provision(groups: [String]) -> Data {
        let list = groups.map { "<string>\($0)</string>" }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>x</string><key>Entitlements</key><dict>
        <key>com.apple.security.application-groups</key><array>\(list)</array></dict></dict></plist>
        """
        // The profile is signed: binary around the text
        return Data([0x30, 0x82, 0x01, 0x00, 0xff]) + Data(xml.utf8) + Data([0x00, 0x42, 0xfe])
    }

    func testTheGroupSideStoreGaveIsReadFromTheProfile() {
        let found = WidgetStorage.groups(inProvision: provision(groups: ["group.app.sapoche.sapoche.ABCDE12345"]))
        XCTAssertEqual(found, ["group.app.sapoche.sapoche.ABCDE12345"])
    }

    func testAProfileWithoutGroupsOrNotAProfileHasNone() {
        XCTAssertEqual(WidgetStorage.groups(inProvision: provision(groups: [])), [])
        XCTAssertEqual(WidgetStorage.groups(inProvision: Data("nothing here".utf8)), [])
    }

    func testTheTeamsNameIsTriedBeforeThePlainOne() {
        let names = WidgetStorage.candidates(provisioned: ["group.other", "group.app.sapoche.sapoche.ABCDE12345"], listed: ["group.app.sapoche.sapoche"])
        XCTAssertEqual(names, ["group.app.sapoche.sapoche.ABCDE12345", "group.app.sapoche.sapoche"])
        XCTAssertEqual(WidgetStorage.candidates(provisioned: [], listed: []), [WidgetStorage.defaultGroup])
    }

    // ------------------------------------------------------------------ buttons

    func testEveryCommandSurvivesBeingText() {
        let commands: [WidgetCommand] = [.playPause, .next, .previous, .jump("a:b"), .quick(.liked, playlist: 0), .quick(.mix, playlist: 0),
                                         .quick(.downloads, playlist: 0), .quick(.playlist, playlist: 12)]
        for command in commands { XCTAssertEqual(WidgetCommand(command.text), command, command.text) }
    }

    func testTextThatIsNoCommandIsNone() {
        for text in ["", "dance", "jump", "jump:", "quick", "quick:nothing", "quick:playlist", "quick:playlist:x", "next:1"] {
            XCTAssertNil(WidgetCommand(text), text)
        }
    }

    // ------------------------------------------------------------------ friends

    private func info(_ exists: Bool, who: [String] = [], name: String? = nil, title: String? = nil) -> [String: Any] {
        var json: [String: Any] = ["exists": exists, "who": who]
        if let name { json["name"] = name }
        if let title { json["title"] = title }
        return json
    }

    func testTheRecentRoomsAreReadFromWhatTheScreensKeep() {
        let rooms = WidgetSnapshot.Friends.recent(#"[{"code":"AAA111","name":"Mine","at":5},{"code":"","at":4},{"code":"BBB222","name":"","at":3},{"nope":1}]"#)
        XCTAssertEqual(rooms.map(\.code), ["AAA111", "BBB222"])
        XCTAssertEqual(rooms.map(\.name), ["Mine", nil])
        XCTAssertTrue(WidgetSnapshot.Friends.recent(nil).isEmpty)
        XCTAssertTrue(WidgetSnapshot.Friends.recent("not json").isEmpty)
    }

    func testTheRoomWithPeopleInItIsWhatFriendsShows() {
        let friends = WidgetSnapshot.Friends.choose([
            (code: "AAA111", name: "Empty", info: info(true)),
            (code: "BBB222", name: "Old name", info: info(true, who: ["Lan", "Minh"], name: "Weekend", title: "STAY")),
        ])
        XCTAssertEqual(friends, .init(code: "BBB222", room: "Weekend", who: ["Lan", "Minh"], song: "STAY"))
    }

    func testWithNobodyListeningTheLastRoomIsShown() {
        let friends = WidgetSnapshot.Friends.choose([(code: "AAA111", name: "Mine", info: info(true))])
        XCTAssertEqual(friends, .init(code: "AAA111", room: "Mine", who: [], song: nil))
    }

    func testARoomTheServerNoLongerHasOrCannotBeReachedIsLeftOut() {
        XCTAssertNil(WidgetSnapshot.Friends.choose([(code: "AAA111", name: nil, info: info(false)), (code: "BBB222", name: nil, info: nil)]))
        XCTAssertNil(WidgetSnapshot.Friends.choose([]))
    }
}
