import XCTest
@testable import DemoTape

final class AutoDirectorTests: XCTestCase {

    private func metadata(duration: Double, clickTimes: [Double]) -> RecordingMetadata {
        RecordingMetadata(
            startedAt: Date(), duration: duration, capturedKeystrokes: true,
            cameraStartOffset: 0, eventTimeOffset: 0,
            display: DisplayInfo(pointWidth: 1440, pointHeight: 900, pixelWidth: 2880, pixelHeight: 1800, scale: 2),
            cursor: [],
            clicks: clickTimes.map { ClickSample(t: $0, x: 0.5, y: 0.5, button: "left") },
            scrolls: [], keys: [])
    }

    private func webcamSwitches(_ tl: Timeline) -> [EditEvent] {
        tl.events.filter { if case .switchAngle(.webcam) = $0.kind { return true }; return false }
    }

    func testCutsToWebcamDuringACalmGap() {
        // Activity early, then a long silent pause → the director should cut to the presenter.
        let md = metadata(duration: 30, clickTimes: [1, 2, 3, 4, 5])   // then silence 5…30
        let tl = AutoDirector.plan(metadata: md, hasWebcam: true)
        let cuts = webcamSwitches(tl)
        XCTAssertFalse(cuts.isEmpty, "a long pause with a webcam should produce a presenter cut")
        // The cut must land inside the calm gap (after the last click at t=5).
        XCTAssertGreaterThan(cuts[0].start, 5.0, "the cut must fall in the pause, not during clicks")
    }

    func testNoWebcamCutsWithoutAWebcam() {
        let md = metadata(duration: 30, clickTimes: [1, 2, 3])
        let tl = AutoDirector.plan(metadata: md, hasWebcam: false)
        XCTAssertTrue(webcamSwitches(tl).isEmpty, "no webcam → never switch to the presenter")
    }

    func testStaysOnScreenDuringConstantActivity() {
        // A click every second for the whole clip → no calm gaps → stay on screen.
        let md = metadata(duration: 25, clickTimes: Array(stride(from: 1.0, to: 25.0, by: 1.0)))
        let tl = AutoDirector.plan(metadata: md, hasWebcam: true)
        XCTAssertTrue(webcamSwitches(tl).isEmpty, "constant clicking should keep the director on the screen")
    }

    func testEveryWebcamCutSwitchesBackToScreen() {
        let md = metadata(duration: 40, clickTimes: [1, 2, 3, 4, 5])   // long pause after
        let tl = AutoDirector.plan(metadata: md, hasWebcam: true)
        let toWebcam = webcamSwitches(tl).count
        let toScreen = tl.events.filter { if case .switchAngle(.screen) = $0.kind { return true }; return false }.count
        XCTAssertEqual(toWebcam, toScreen, "each presenter cut must return to the screen")
    }

    func testAlwaysFadesAndDoesNotZoomTheScreen() {
        // No webcam: the director must NOT add zoom (the styled auto-zoom owns the screen);
        // it only bookends with fades.
        let md = metadata(duration: 20, clickTimes: [1, 2, 3])
        let tl = AutoDirector.plan(metadata: md, hasWebcam: false)
        XCTAssertTrue(tl.events.contains { $0.kind == .fadeIn }, "should fade in")
        XCTAssertTrue(tl.events.contains { $0.kind == .fadeToBlack }, "should fade out")
        let hasZoom = tl.events.contains { if case .zoomIn = $0.kind { return true }; return false }
        XCTAssertFalse(hasZoom, "without a webcam the director must not re-zoom the screen")
    }

    func testWebcamShotGetsKenBurnsAndReset() {
        let md = metadata(duration: 30, clickTimes: [1, 2, 3, 4, 5])   // long pause after
        let tl = AutoDirector.plan(metadata: md, hasWebcam: true)
        let hasZoom = tl.events.contains { if case .zoomIn = $0.kind { return true }; return false }
        let hasPan = tl.events.contains { if case .pan = $0.kind { return true }; return false }
        XCTAssertTrue(hasZoom, "webcam shot should have a gentle push-in")
        XCTAssertTrue(hasPan, "webcam shot should pan")
        // Zoom must return to 1× at the cut back to screen so the screen isn't left zoomed.
        let resets = tl.events.contains { if case .zoomIn(let a) = $0.kind { return a == 1.0 }; return false }
        XCTAssertTrue(resets, "zoom should reset to 1× on the cut back to screen")
    }

    func testAllPansAreLeftToRight() {
        // Cinematography: left→right reads as natural. Every pan must have a positive x.
        let md = metadata(duration: 60, clickTimes: [1, 2, 3, 20, 21, 22])   // two pauses
        let tl = AutoDirector.plan(metadata: md, hasWebcam: true)
        for e in tl.events {
            if case .pan(let fx, _) = e.kind {
                XCTAssertGreaterThan(fx, 0, "pans must sweep left→right (positive x), never right→left")
            }
        }
    }

    func testCalmGapsDetection() {
        let md = metadata(duration: 20, clickTimes: [1, 2, 10, 11])   // gap 2→10
        let gaps = AutoDirector.calmGaps(metadata: md, duration: 20, minGap: 3)
        XCTAssertTrue(gaps.contains { $0.start <= 2.01 && $0.end >= 9.99 }, "should detect the 2→10 gap")
        XCTAssertTrue(gaps.contains { $0.end >= 20 }, "should detect the trailing pause 11→20")
    }
}
