import XCTest
@testable import SapocheCore

final class DownloadActivityTests: XCTestCase {
    private func batch(_ active: String?, _ done: Int, _ total: Int, _ failed: Int = 0) -> Downloader.Batch {
        Downloader.Batch(active: active, done: done, total: total, failed: failed)
    }

    private func content(_ title: String, _ done: Int, _ total: Int, failed: Int = 0, finished: Bool = false, paused: Bool = false) -> DownloadActivityContent {
        DownloadActivityContent(title: title, done: done, total: total, failed: failed, finished: finished, paused: paused, language: "en")
    }

    private func step(_ plan: inout DownloadActivityPlan, _ batch: Downloader.Batch, _ title: String = "", canOpen: Bool = true, quiet: Bool = false) -> DownloadActivityPlan.Step {
        plan.step(batch, title: title, language: "en", canOpen: canOpen, quiet: quiet)
    }

    func testARunIsOpenedChangedWithEachSongAndClosedWithHowItWent() {
        var plan = DownloadActivityPlan()
        XCTAssertEqual(step(&plan, batch("a", 0, 3), "A"), .start(content("A", 0, 3)))
        XCTAssertEqual(step(&plan, batch("a", 0, 3), "A"), .none, "the same thing again is not sent: the system refuses updates that come in a heap")
        XCTAssertEqual(step(&plan, batch("b", 1, 3), "B"), .update(content("B", 1, 3)))
        XCTAssertEqual(step(&plan, batch("c", 1, 3, 1), "C"), .update(content("C", 1, 3, failed: 1)))
        XCTAssertEqual(step(&plan, batch(nil, 2, 3, 1)), .finish(content("", 2, 3, failed: 1, finished: true)))
        XCTAssertEqual(step(&plan, batch(nil, 2, 3, 1)), .none, "it is over once")
    }

    func testARunMetWhileTheAppIsNotInFrontOrOneThePhoneMakesByItselfOpensNothing() {
        var plan = DownloadActivityPlan()
        XCTAssertEqual(step(&plan, batch("a", 0, 3), "A", canOpen: false), .none)
        XCTAssertEqual(step(&plan, batch("a", 0, 3), "A", quiet: true), .none)
        XCTAssertEqual(step(&plan, batch(nil, 3, 3)), .none, "and nothing to close")
    }

    func testARunCutShortTakesTheActivityAwayAtOnce() {
        var plan = DownloadActivityPlan()
        _ = step(&plan, batch("a", 0, 3), "A")
        XCTAssertEqual(step(&plan, .idle), .close)
        XCTAssertEqual(step(&plan, .idle), .none)
    }

    func testTheTimeRunningOutPausesItAndTheNextNewsOfTheRunGoesOn() {
        var plan = DownloadActivityPlan()
        XCTAssertEqual(plan.timeUp(), .none, "nothing is open")
        _ = step(&plan, batch("a", 0, 3), "A")
        XCTAssertEqual(plan.timeUp(), .update(content("A", 0, 3, paused: true)))
        XCTAssertEqual(plan.timeUp(), .none, "once")
        XCTAssertEqual(step(&plan, batch("a", 0, 3), "A"), .update(content("A", 0, 3)), "the app is open again, the same song goes on")
    }

    func testTheWordsFollowTheLanguageAndTheState() {
        let vi = { (done: Int, total: Int, failed: Int, finished: Bool, paused: Bool) in
            DownloadActivityContent(title: "Bài", done: done, total: total, failed: failed, finished: finished, paused: paused, language: "vi")
        }
        XCTAssertEqual(content("A", 2, 25).headline(), "Downloading 3 of 25")
        XCTAssertEqual(vi(2, 25, 0, false, false).headline(), "Đang tải 3/25")
        XCTAssertEqual(content("A", 2, 25).subline(), "A")
        XCTAssertEqual(content("A", 2, 25).headline(stale: true), "Paused")
        XCTAssertEqual(vi(2, 25, 0, false, true).headline(), "Tạm dừng")
        XCTAssertEqual(vi(2, 25, 0, false, true).subline(), "Mở Sapoche để tải tiếp")
        XCTAssertEqual(content("", 25, 25, finished: true).headline(), "Downloaded 25 songs")
        XCTAssertEqual(content("", 1, 1, finished: true).headline(), "Downloaded 1 song")
        XCTAssertEqual(vi(23, 25, 2, true, false).headline(), "Đã tải 23 bài, 2 bài không tải được")
        XCTAssertEqual(vi(25, 25, 0, true, false).headline(), "Đã tải xong 25 bài")
    }

    func testThePlaceNeverRunsPastTheTotalAndTheBarFills() {
        XCTAssertEqual(content("A", 3, 3).position, 3)
        XCTAssertEqual(content("A", 0, 0).position, 1)
        XCTAssertEqual(content("A", 1, 4).fraction, 0.25)
        XCTAssertEqual(content("A", 0, 0).fraction, 0)
    }

    func testTheContentSurvivesTheTripBetweenTheAppAndTheWidgets() throws {
        let sent = content("A", 1, 3, failed: 1, paused: true)
        let back = try JSONDecoder().decode(DownloadActivityContent.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(back, sent)
    }
}
