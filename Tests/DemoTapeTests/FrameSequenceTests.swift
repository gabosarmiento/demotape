import XCTest
import CoreGraphics
@testable import DemoTape

/// Screencast frames arrive with duplicate and out-of-order timestamps as a matter of course, and a
/// writer rejects a non-increasing presentation time — so normalizing the timeline is part of reading
/// the manifest. These cover that, plus path resolution and size inference.
final class FrameSequenceTests: XCTestCase {

    private let dir = URL(fileURLWithPath: "/tmp/demotape-frames")

    private func decode(_ json: String) -> FrameSequence {
        try! JSONDecoder().decode(FrameSequence.self, from: json.data(using: .utf8)!)
    }

    func testResolvesRelativePathsAgainstTheManifestDirectory() {
        let s = decode(#"{ "frames": [ { "path": "0001.jpg", "t": 0 }, { "path": "0002.jpg", "t": 0.1 } ] }"#)
        let r = s.resolve(relativeTo: dir)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].url.path, "/tmp/demotape-frames/0001.jpg")
        XCTAssertEqual(r[1].url.path, "/tmp/demotape-frames/0002.jpg")
    }

    func testAbsolutePathsArePreserved() {
        let s = decode(#"{ "frames": [ { "path": "/var/tmp/a.jpg", "t": 0 } ] }"#)
        XCTAssertEqual(s.resolve(relativeTo: dir)[0].url.path, "/var/tmp/a.jpg")
    }

    func testMissingTimestampsAreSynthesizedFromFps() {
        let s = decode(#"{ "fps": 10, "frames": [ { "path": "a.jpg" }, { "path": "b.jpg" }, { "path": "c.jpg" } ] }"#)
        let r = s.resolve(relativeTo: dir)
        XCTAssertEqual(r[0].t, 0.0, accuracy: 1e-9)
        XCTAssertEqual(r[1].t, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r[2].t, 0.2, accuracy: 1e-9)
    }

    func testTimelineIsAlwaysStrictlyIncreasing() {
        // Duplicates and a backwards step — exactly what a screencast delivers.
        let s = decode(#"""
        { "fps": 30, "frames": [
            { "path": "a.jpg", "t": 0.00 },
            { "path": "b.jpg", "t": 0.00 },
            { "path": "c.jpg", "t": 0.05 },
            { "path": "d.jpg", "t": 0.04 },
            { "path": "e.jpg", "t": 0.05 }
        ] }
        """#)
        let r = s.resolve(relativeTo: dir)
        XCTAssertEqual(r.count, 5, "no captured frame should be dropped")
        for i in 1..<r.count {
            XCTAssertGreaterThan(r[i].t, r[i - 1].t, "frame \(i) did not advance")
        }
    }

    func testNegativeAndNonFiniteTimestampsAreRejected() {
        let s = decode(#"{ "frames": [ { "path": "a.jpg", "t": -1 }, { "path": "b.jpg", "t": 0.5 } ] }"#)
        let r = s.resolve(relativeTo: dir)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].t, 0.5, accuracy: 1e-9)
    }

    func testEmptyManifestResolvesToNothing() {
        XCTAssertTrue(decode(#"{ "frames": [] }"#).resolve(relativeTo: dir).isEmpty)
    }

    func testDeclaredSizeIsUsedOnlyWhenUsable() {
        XCTAssertEqual(decode(#"{ "width": 1280, "height": 800, "frames": [] }"#).declaredSize,
                       CGSize(width: 1280, height: 800))
        XCTAssertNil(decode(#"{ "frames": [] }"#).declaredSize)
        XCTAssertNil(decode(#"{ "width": 0, "height": 800, "frames": [] }"#).declaredSize)
        XCTAssertNil(decode(#"{ "width": 1280, "frames": [] }"#).declaredSize)
    }

    func testZeroFpsFallsBackInsteadOfDividingByZero() {
        let s = decode(#"{ "fps": 0, "frames": [ { "path": "a.jpg" }, { "path": "b.jpg" } ] }"#)
        let r = s.resolve(relativeTo: dir)
        XCTAssertEqual(r.count, 2)
        XCTAssertTrue(r[1].t.isFinite)
        XCTAssertGreaterThan(r[1].t, r[0].t)
    }
}
