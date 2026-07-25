import XCTest
@testable import DemoTape

/// The typing camera: it must HOLD on the field while text is entered, and PAN smoothly as the text
/// grows. Both were bugs — the hold lapsed mid-sentence, and the pan vibrated because reported caret
/// positions repeat and arrive out of order.
final class FocusTimelineTypingTests: XCTestCase {

    private func metadata(clicks: [ClickSample] = [], keys: [KeySample] = [],
                          duration: Double = 20) -> RecordingMetadata {
        RecordingMetadata(
            startedAt: Date(), duration: duration, capturedKeystrokes: true,
            cameraStartOffset: nil, eventTimeOffset: nil,
            display: DisplayInfo(pointWidth: 1440, pointHeight: 900,
                                 pixelWidth: 1440, pixelHeight: 900, scale: 1),
            cursor: [CursorSample(t: 0, x: 0.9, y: 0.9)],
            clicks: clicks, scrolls: [], keys: keys)
    }

    private func key(_ t: Double, x: Double? = nil, y: Double? = nil) -> KeySample {
        KeySample(t: t, keyCode: -1, chars: "", modifiers: [], x: x, y: y)
    }

    // MARK: - Anchor while typing

    func testTypingAnchorsOnTheClickedFieldWhenNoCaretIsReported() {
        // Real keystrokes carry no position, so the field's click is the anchor.
        let m = metadata(clicks: [ClickSample(t: 1.0, x: 0.1, y: 0.8, button: "left")],
                         keys: [key(1.2), key(1.4)])
        let anchor = FocusTimeline(metadata: m).focusAnchor(at: 1.5)
        XCTAssertEqual(Double(anchor.x), 0.1, accuracy: 0.001)
        XCTAssertEqual(Double(anchor.y), 0.8, accuracy: 0.001)
    }

    func testCaretOverridesTheClickAnchor() {
        // With a caret reported, the camera should follow the text instead of the click point.
        let m = metadata(clicks: [ClickSample(t: 1.0, x: 0.1, y: 0.8, button: "left")],
                         keys: [key(1.2, x: 0.30, y: 0.8), key(1.4, x: 0.30, y: 0.8)])
        let anchor = FocusTimeline(metadata: m).focusAnchor(at: 1.45)
        XCTAssertGreaterThan(Double(anchor.x), 0.15, "should have moved off the click point")
    }

    // MARK: - No vibration

    func testAnchorNeverGoesBackwardsWhenSamplesArriveOutOfOrder() {
        // Overlapping batches report a stale x after a fresher one. Taking "the latest" makes the
        // anchor snap backwards — the vibration. It must be monotonic within a typing run.
        let m = metadata(clicks: [ClickSample(t: 1.0, x: 0.05, y: 0.8, button: "left")],
                         keys: [key(1.1, x: 0.10, y: 0.8), key(1.2, x: 0.30, y: 0.8),
                                key(1.3, x: 0.20, y: 0.8),   // stale, arrives later
                                key(1.4, x: 0.35, y: 0.8)])
        let tl = FocusTimeline(metadata: m)
        var previous = -Double.infinity
        for step in stride(from: 1.1, through: 1.45, by: 0.02) {
            let x = Double(tl.focusAnchor(at: step).x)
            XCTAssertGreaterThanOrEqual(x, previous - 1e-6, "anchor jumped backwards at t=\(step)")
            previous = x
        }
    }

    func testPanIsContinuousRatherThanStepped() {
        // Sampled the way the recorder actually gets them — one per character, ~14/s, with the caret
        // advancing steadily. Frame to frame the anchor must creep, never jump.
        var keys: [KeySample] = []
        var t = 1.0
        var x = 0.10
        while t < 4.0 {
            keys.append(key(t, x: x, y: 0.8))
            t += 1.0 / 14.0
            x += 0.004
        }
        let tl = FocusTimeline(metadata: metadata(
            clicks: [ClickSample(t: 0.9, x: 0.05, y: 0.8, button: "left")], keys: keys))

        var previous = Double(tl.focusAnchor(at: 1.05).x)
        var biggestJump = 0.0
        for step in stride(from: 1.05, through: 3.9, by: 1.0 / 30.0) {   // per video frame
            let current = Double(tl.focusAnchor(at: step).x)
            biggestJump = max(biggestJump, abs(current - previous))
            previous = current
        }
        // A frame-to-frame move this small is a pan; anything larger is visible as a stutter.
        XCTAssertLessThan(biggestJump, 0.01, "pan stepped instead of easing (jump \(biggestJump))")
        // And it must actually track the caret, not merely avoid jumping. The caret ends near 0.26
        // (0.10 plus ~40 characters at 0.004 each); the smoothed anchor should trail it slightly.
        let caretAtEnd = 0.10 + 0.004 * ((3.9 - 1.0) * 14.0)
        let anchorAtEnd = Double(tl.focusAnchor(at: 3.9).x)
        XCTAssertGreaterThan(anchorAtEnd, 0.20, "pan never followed the text")
        XCTAssertLessThanOrEqual(anchorAtEnd, caretAtEnd + 0.01, "anchor ran ahead of the caret")
        XCTAssertGreaterThan(anchorAtEnd, caretAtEnd - 0.06, "anchor lagged too far behind the caret")
    }

    func testANewTypingRunStartsAFreshPan() {
        // A long gap means a different field or sentence; the anchor must not ease from the old one.
        let m = metadata(clicks: [ClickSample(t: 1.0, x: 0.05, y: 0.2, button: "left")],
                         keys: [key(1.1, x: 0.60, y: 0.2),
                                key(9.0, x: 0.12, y: 0.85), key(9.2, x: 0.16, y: 0.85)])
        let anchor = FocusTimeline(metadata: m).focusAnchor(at: 9.25)
        XCTAssertEqual(Double(anchor.y), 0.85, accuracy: 0.01, "should track the NEW field")
        XCTAssertLessThan(Double(anchor.x), 0.3, "should not still be panned to the old run")
    }

    // MARK: - Hold

    func testActivityStaysHighAcrossAGapInsideTheHold() {
        // Samples ~0.7s apart must keep the zoom engaged; that's what the heartbeat guarantees.
        let m = metadata(keys: [key(1.0), key(1.7), key(2.4)])
        let tl = FocusTimeline(metadata: m)
        for step in stride(from: 1.0, through: 2.4, by: 0.1) {
            XCTAssertGreaterThan(tl.activity(at: step), 0.9,
                                 "zoom decayed mid-sentence at t=\(step)")
        }
    }
}
