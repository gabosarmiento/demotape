import XCTest
@testable import DemoTape

final class SpeedScaleTests: XCTestCase {

    func testSnapRoundsToNearestTenth() {
        XCTAssertEqual(SpeedScale.snap(1.23, min: 0.5, max: 2.0), 1.2, accuracy: 1e-9)
        XCTAssertEqual(SpeedScale.snap(1.26, min: 0.5, max: 2.0), 1.3, accuracy: 1e-9)
        XCTAssertEqual(SpeedScale.snap(0.949, min: 0.5, max: 2.0), 0.9, accuracy: 1e-9)
    }

    func testSnapClampsToRange() {
        XCTAssertEqual(SpeedScale.snap(0.1, min: 0.5, max: 2.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SpeedScale.snap(9.0, min: 0.5, max: 2.0), 2.0, accuracy: 1e-9)
    }

    func testSnapHasNoFloatingPointFuzz() {
        // 1.1 + 0.1 style arithmetic must not leave 1.2000000000000002.
        let v = SpeedScale.snap(1.2000000000000002, min: 0.5, max: 2.0)
        XCTAssertEqual(v, 1.2, accuracy: 1e-12)
        XCTAssertEqual("\(v)", "1.2")
    }

    func testStepMovesByOneTenthAndClamps() {
        XCTAssertEqual(SpeedScale.step(1.0, by: 0.1, min: 0.5, max: 2.0), 1.1, accuracy: 1e-9)
        XCTAssertEqual(SpeedScale.step(1.0, by: -0.1, min: 0.5, max: 2.0), 0.9, accuracy: 1e-9)
        XCTAssertEqual(SpeedScale.step(2.0, by: 0.1, min: 0.5, max: 2.0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(SpeedScale.step(0.5, by: -0.1, min: 0.5, max: 2.0), 0.5, accuracy: 1e-9)
    }

    func testFormatDropsDecimalForWholeNumbers() {
        XCTAssertEqual(SpeedScale.format(1.0), "1×")
        XCTAssertEqual(SpeedScale.format(2.0), "2×")
        XCTAssertEqual(SpeedScale.format(0.5), "0.5×")
        XCTAssertEqual(SpeedScale.format(1.2), "1.2×")
    }

    func testTickCountCoversEveryTenth() {
        XCTAssertEqual(SpeedScale.tickCount(min: 0.5, max: 2.0), 16)  // 0.5…2.0 inclusive
        XCTAssertEqual(SpeedScale.tickCount(min: 1.0, max: 2.0), 11)
    }

    func testIsRecommendedBand() {
        XCTAssertTrue(SpeedScale.isRecommended(1.0, low: 0.8, high: 1.5))
        XCTAssertTrue(SpeedScale.isRecommended(0.8, low: 0.8, high: 1.5))
        XCTAssertTrue(SpeedScale.isRecommended(1.5, low: 0.8, high: 1.5))
        XCTAssertFalse(SpeedScale.isRecommended(0.5, low: 0.8, high: 1.5))
        XCTAssertFalse(SpeedScale.isRecommended(2.0, low: 0.8, high: 1.5))
    }
}
