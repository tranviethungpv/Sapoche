import XCTest
@testable import SapocheCore

final class LoudnessTests: XCTestCase {
    /// The same table is in `LoudnessTest.kt`: the two platforms must turn a song down by the same amount.
    func testASongAboveTheReferenceLevelIsTurnedDownByThatMuchTheRestIsLeftAlone() {
        let table: [(Double?, Float)] = [
            (nil, 1), (.nan, 1), (-3, 1), (0, 1), (0.99, 0.8923), (3, 0.7079), (6.55, 0.4704), (12, 0.2512), (30, 0.2512),
        ]
        for (db, factor) in table {
            XCTAssertEqual(Loudness.gain(db), factor, accuracy: 0.0001, "gain of \(String(describing: db)) dB")
        }
    }
}
