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

    // MARK: - Held timeline
    //
    // A screencast only paints on change, so a static page yields a handful of frames a second. The
    // renderer draws one output frame per source frame and cannot invent the ones between, so without
    // holding, the synthetic cursor would move a few times a second and read as a stutter.

    func testHeldTimelineFillsASparseCaptureToTheRate() {
        // 3 frames across 1 second, asked for 30fps.
        let s = decode(#"""
        { "fps": 30, "frames": [
            { "path": "a.jpg", "t": 0.0 },
            { "path": "b.jpg", "t": 0.4 },
            { "path": "c.jpg", "t": 1.0 }
        ] }
        """#)
        let held = s.heldTimeline(relativeTo: dir, rate: 30)
        XCTAssertGreaterThan(held.count, 25, "should fill toward 30 frames for a 1s span")
        for i in 1..<held.count {
            XCTAssertGreaterThan(held[i].t, held[i - 1].t)
        }
        // Each slot shows the newest frame at or before it — never a future one.
        XCTAssertEqual(held.first?.url.lastPathComponent, "a.jpg")
        XCTAssertEqual(held.last?.url.lastPathComponent, "c.jpg")
        let at0_5 = held.first(where: { $0.t >= 0.5 })
        XCTAssertEqual(at0_5?.url.lastPathComponent, "b.jpg", "0.5s should still hold b, not reach c")
    }

    func testHeldTimelineNeverShowsAFrameBeforeItWasCaptured() {
        let s = decode(#"""
        { "fps": 20, "frames": [
            { "path": "a.jpg", "t": 0.0 },
            { "path": "b.jpg", "t": 0.75 }
        ] }
        """#)
        for f in s.heldTimeline(relativeTo: dir, rate: 20) where f.url.lastPathComponent == "b.jpg" {
            XCTAssertGreaterThanOrEqual(f.t, 0.75 - 1e-9)
        }
    }

    func testHeldTimelineRunsToTheCaptureDurationNotTheLastFrame() {
        // The page stopped repainting at 1.0s but the capture ran to 3.0s — which is the normal case,
        // because the closing beat of a demo is a still result. Ending at the last frame cuts that beat
        // off and leaves the final narration line with no video under it.
        let s = decode(#"""
        { "fps": 30, "duration": 3.0, "frames": [
            { "path": "a.jpg", "t": 0.0 },
            { "path": "b.jpg", "t": 1.0 }
        ] }
        """#)
        let held = s.heldTimeline(relativeTo: dir, rate: 30)
        XCTAssertEqual(held.last?.t ?? 0, 3.0, accuracy: 1.0 / 30,
                       "the timeline should reach the end of the capture")
        XCTAssertEqual(held.last?.url.lastPathComponent, "b.jpg",
                       "the final image should be held, not dropped")
        XCTAssertGreaterThan(held.count, 85, "≈3s at 30fps")
    }

    func testHeldTimelineIgnoresADurationShorterThanTheFrames() {
        // A bogus/short duration must not truncate real frames.
        let s = decode(#"""
        { "fps": 30, "duration": 0.2, "frames": [
            { "path": "a.jpg", "t": 0.0 },
            { "path": "b.jpg", "t": 1.0 }
        ] }
        """#)
        let held = s.heldTimeline(relativeTo: dir, rate: 30)
        XCTAssertEqual(held.last?.t ?? 0, 1.0, accuracy: 1.0 / 30)
    }

    func testHeldTimelineLeavesADenseCaptureAlone() {
        // Already 30fps across 1s — nothing to fill, so don't touch it.
        var frames: [String] = []
        for i in 0..<31 { frames.append("{ \"path\": \"f\(i).jpg\", \"t\": \(Double(i) / 30) }") }
        let s = decode("{ \"fps\": 30, \"frames\": [\(frames.joined(separator: ","))] }")
        let held = s.heldTimeline(relativeTo: dir, rate: 30)
        XCTAssertEqual(held.count, 31)
    }

    func testHeldTimelineHandlesDegenerateInput() {
        XCTAssertTrue(decode(#"{ "frames": [] }"#).heldTimeline(relativeTo: dir, rate: 30).isEmpty)
        let single = decode(#"{ "frames": [ { "path": "a.jpg", "t": 0 } ] }"#)
        XCTAssertEqual(single.heldTimeline(relativeTo: dir, rate: 30).count, 1)
        // A zero/negative rate must not hang or divide by zero.
        let s = decode(#"{ "frames": [ { "path": "a.jpg", "t": 0 }, { "path": "b.jpg", "t": 1 } ] }"#)
        XCTAssertEqual(s.heldTimeline(relativeTo: dir, rate: 0).count, 2)
    }

    func testZeroFpsFallsBackInsteadOfDividingByZero() {
        let s = decode(#"{ "fps": 0, "frames": [ { "path": "a.jpg" }, { "path": "b.jpg" } ] }"#)
        let r = s.resolve(relativeTo: dir)
        XCTAssertEqual(r.count, 2)
        XCTAssertTrue(r[1].t.isFinite)
        XCTAssertGreaterThan(r[1].t, r[0].t)
    }
}
