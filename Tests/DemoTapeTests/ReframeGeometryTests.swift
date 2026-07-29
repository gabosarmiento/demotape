import XCTest
import CoreGraphics
@testable import DemoTape

final class ReframeGeometryTests: XCTestCase {

    func testTargetSizeFromKnownRatios() {
        XCTAssertEqual(ReframeGeometry.targetSize(for: "9:16"), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ReframeGeometry.targetSize(for: "1:1"), CGSize(width: 1080, height: 1080))
        XCTAssertEqual(ReframeGeometry.targetSize(for: "4:5"), CGSize(width: 1080, height: 1350))
        XCTAssertEqual(ReframeGeometry.targetSize(for: "16:9"), CGSize(width: 1920, height: 1080))
    }

    func testTargetSizeFromExplicitPixels() {
        XCTAssertEqual(ReframeGeometry.targetSize(for: "1080x1920"), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ReframeGeometry.targetSize(for: "720x1280"), CGSize(width: 720, height: 1280))
    }

    func testTargetSizeArbitraryRatioUsesShortSide1080() {
        // Matches the standard sizes (9:16 → 1080×1920): the short side is 1080.
        let s = ReframeGeometry.targetSize(for: "2:3")   // portrait → width 1080, height 1620
        XCTAssertEqual(s?.width ?? 0, 1080, accuracy: 1)
        XCTAssertEqual(s?.height ?? 0, 1620, accuracy: 1)
    }

    func testTargetSizeRejectsGarbage() {
        XCTAssertNil(ReframeGeometry.targetSize(for: "nonsense"))
        XCTAssertNil(ReframeGeometry.targetSize(for: "0x0"))
    }
}
