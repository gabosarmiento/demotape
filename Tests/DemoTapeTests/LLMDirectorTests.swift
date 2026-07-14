import XCTest
@testable import DemoTape

final class LLMDirectorTests: XCTestCase {

    private func metadata(duration: Double, clicks: [Double]) -> RecordingMetadata {
        RecordingMetadata(
            startedAt: Date(), duration: duration, capturedKeystrokes: true,
            cameraStartOffset: 0, eventTimeOffset: 0,
            display: DisplayInfo(pointWidth: 1440, pointHeight: 900, pixelWidth: 2880, pixelHeight: 1800, scale: 2),
            cursor: [],
            clicks: clicks.map { ClickSample(t: $0, x: 0.5, y: 0.5, button: "left") },
            scrolls: [], keys: [])
    }

    func testTimelineTextInterleavesNarrationAndActivity() {
        let md = metadata(duration: 20, clicks: [3.0])
        let cues = [CaptionCue(start: 1.0, end: 2.0, text: "Welcome to the demo"),
                    CaptionCue(start: 5.0, end: 6.0, text: "Now watch this")]
        let text = LLMDirector.timelineText(metadata: md, cues: cues)
        XCTAssertTrue(text.contains("SAY: Welcome to the demo"))
        XCTAssertTrue(text.contains("DO: on-screen activity"))
        // Ordered by time: the first narration line precedes the click marker.
        let sayIdx = text.range(of: "Welcome")!.lowerBound
        let doIdx = text.range(of: "DO:")!.lowerBound
        XCTAssertLessThan(sayIdx, doIdx)
    }

    func testParseShotsToleratesProseAndFences() {
        let content = """
        Sure! Here is the plan:
        ```json
        {"shots":[
          {"start":0,"end":4,"framing":"presenter_full","move":"push_in"},
          {"start":4,"end":12,"framing":"screen","move":"still"},
          {"start":12,"end":16,"framing":"presenter_close","move":"pan"}
        ]}
        ```
        """
        let shots = LLMDirector.parseShots(fromContent: content)
        XCTAssertEqual(shots.count, 3)
        XCTAssertEqual(shots[0].framing, .presenterFull)
        XCTAssertEqual(shots[0].move, .pushIn)
        XCTAssertEqual(shots[1].framing, .screen)
        XCTAssertEqual(shots[2].framing, .presenterClose)
        XCTAssertEqual(shots[2].move, .panRight)
    }

    func testParseShotsReturnsEmptyOnGarbage() {
        XCTAssertTrue(LLMDirector.parseShots(fromContent: "no json here").isEmpty)
    }

    func testSanitizeFillsGapsWithScreenAndDropsShortShots() {
        // A too-short presenter shot is dropped; gaps become screen; whole timeline covered.
        let raw = [DirectorShot(start: 5, end: 9, framing: .presenterFull, move: .pushIn),
                   DirectorShot(start: 9.5, end: 10.0, framing: .presenterClose, move: .still)]  // too short
        let clean = ShotPlanner.sanitize(raw, duration: 30)
        XCTAssertEqual(clean.first?.framing, .screen, "opens on screen before the first presenter shot")
        XCTAssertEqual(clean.last?.end ?? 0, 30, accuracy: 0.001, "covers the whole timeline")
        XCTAssertTrue(clean.contains { $0.framing == .presenterFull })
        XCTAssertFalse(clean.contains { $0.framing == .presenterClose }, "the 0.5s shot was dropped")
    }

    func testLocalPlanStaysOnScreenWithoutWebcam() {
        let md = metadata(duration: 20, clicks: [1, 2, 3])
        let shots = ShotPlanner.local(metadata: md, hasWebcam: false, duration: 20)
        XCTAssertEqual(shots.count, 1)
        XCTAssertEqual(shots[0].framing, .screen)
    }

    func testGenrePlanCoversTimelineAndVariesFraming() {
        // Activity early, then long pauses → several presenter opportunities.
        let md = metadata(duration: 60, clicks: [1, 2, 3, 20, 21, 40, 41])
        let shots = ShotPlanner.genre(.social, metadata: md, hasWebcam: true, duration: 60)
        XCTAssertEqual(shots.first?.start ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(shots.last?.end ?? 0, 60, accuracy: 0.001, "covers the whole timeline")
        // Shots must be contiguous (no gaps/overlaps).
        for i in 1..<shots.count {
            XCTAssertEqual(shots[i].start, shots[i - 1].end, accuracy: 0.01, "shots are contiguous")
        }
        XCTAssertTrue(shots.contains { $0.framing != .screen }, "social should cut to the presenter")
    }

    func testGenrePlanScreenOnlyWithoutWebcam() {
        let md = metadata(duration: 30, clicks: [5, 15])
        let shots = ShotPlanner.genre(.keynote, metadata: md, hasWebcam: false, duration: 30)
        XCTAssertEqual(shots.count, 1)
        XCTAssertEqual(shots[0].framing, .screen)
    }
}
