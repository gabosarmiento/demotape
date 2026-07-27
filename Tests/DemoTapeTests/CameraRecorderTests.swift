import XCTest
@testable import DemoTape

/// The camera format policy: the bubble stays small; webcam-only wants full 1080p but never 4K, so
/// the file stays manageable for Web Publish. Only 30fps-capable sizes within the box qualify.
final class CameraRecorderTests: XCTestCase {

    private let sizes: [(w: Int, h: Int, maxFps: Double)] = [
        (640, 480, 30),
        (1280, 720, 30),
        (1920, 1080, 30),
        (3840, 2160, 30),      // 4K — must be excluded for webcam-only
        (1920, 1080, 24)       // 1080p but only 24fps — excluded (needs 30)
    ]

    func testStandaloneAcceptsUpTo1080pAndNever4K() {
        let ok = CameraRecorder.acceptableFormatSizes(sizes, maxWidth: 1920, maxHeight: 1080)
        let accepted = ok.map { (sizes[$0].w, sizes[$0].h, sizes[$0].maxFps) }
        XCTAssertTrue(accepted.contains { $0 == (1920, 1080, 30) })
        XCTAssertTrue(accepted.contains { $0 == (1280, 720, 30) })
        XCTAssertFalse(accepted.contains { $0.0 == 3840 }, "4K must be excluded")
        XCTAssertFalse(accepted.contains { $0.2 == 24 }, "sub-30fps must be excluded")
    }

    func testBubbleStaysWithin720() {
        let ok = CameraRecorder.acceptableFormatSizes(sizes, maxWidth: 1280, maxHeight: 720)
        let accepted = ok.map { (sizes[$0].w, sizes[$0].h) }
        XCTAssertTrue(accepted.contains { $0 == (1280, 720) })
        XCTAssertFalse(accepted.contains { $0 == (1920, 1080) }, "1080p is too big for the bubble")
    }
}
