import XCTest
import CoreGraphics
@testable import DemoTape

final class FocusTimelineTests: XCTestCase {

    private func meta(cursor: [CursorSample] = [],
                      clicks: [ClickSample] = [],
                      keys: [KeySample] = []) -> RecordingMetadata {
        RecordingMetadata(
            startedAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            capturedKeystrokes: !keys.isEmpty,
            cameraStartOffset: nil,
            eventTimeOffset: nil,
            display: DisplayInfo(pointWidth: 1440, pointHeight: 900,
                                 pixelWidth: 2880, pixelHeight: 1800, scale: 2),
            cursor: cursor, clicks: clicks, scrolls: [], keys: keys)
    }

    // MARK: - Activity / zoom

    func testNoActivityMeansNoZoom() {
        let ft = FocusTimeline(metadata: meta(), maxZoom: 2.0)
        XCTAssertEqual(ft.activity(at: 5), 0, accuracy: 1e-9)
        let target = ft.target(at: 5)
        XCTAssertEqual(target.scale, 1.0, accuracy: 1e-9)
        // With no zoom the camera stays centered.
        XCTAssertEqual(target.cx, 0.5, accuracy: 1e-9)
        XCTAssertEqual(target.cy, 0.5, accuracy: 1e-9)
    }

    func testClickDrivesFullZoomDuringHold() {
        let clicks = [ClickSample(t: 1.0, x: 0.3, y: 0.7, button: "left")]
        let ft = FocusTimeline(metadata: meta(clicks: clicks), maxZoom: 2.0)
        // 0.5s into the 1.6s hold window (rampIn is 0.4s), activity should be full.
        XCTAssertEqual(ft.activity(at: 1.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ft.target(at: 1.5).scale, 2.0, accuracy: 1e-9)
    }

    func testActivityDecaysAfterHold() {
        let clicks = [ClickSample(t: 1.0, x: 0.5, y: 0.5, button: "left")]
        let ft = FocusTimeline(metadata: meta(clicks: clicks))
        // Long after the click + ramp-out, activity is back to zero.
        XCTAssertEqual(ft.activity(at: 8.0), 0, accuracy: 1e-9)
    }

    func testActivityAlwaysInUnitRange() {
        let clicks = (0..<5).map { ClickSample(t: Double($0) * 0.2, x: 0.5, y: 0.5, button: "left") }
        let keys = (0..<5).map { KeySample(t: Double($0) * 0.2 + 0.1, keyCode: 0, chars: "a", modifiers: []) }
        let ft = FocusTimeline(metadata: meta(clicks: clicks, keys: keys))
        for i in 0...200 {
            let a = ft.activity(at: Double(i) * 0.05)
            XCTAssertGreaterThanOrEqual(a, 0)
            XCTAssertLessThanOrEqual(a, 1)
        }
    }

    // MARK: - Camera centering / clamping

    func testCameraCenterStaysWithinFrame() {
        // Click near a corner; the camera must clamp so the zoomed frame stays on-screen.
        let clicks = [ClickSample(t: 1.0, x: 0.98, y: 0.02, button: "left")]
        let ft = FocusTimeline(metadata: meta(clicks: clicks), maxZoom: 2.0)
        let target = ft.target(at: 1.5)   // full zoom
        let half = 0.5 / target.scale
        XCTAssertGreaterThanOrEqual(target.cx, half - 1e-9)
        XCTAssertLessThanOrEqual(target.cx, 1 - half + 1e-9)
        XCTAssertGreaterThanOrEqual(target.cy, half - 1e-9)
        XCTAssertLessThanOrEqual(target.cy, 1 - half + 1e-9)
    }

    // MARK: - Text-input tracking

    func testTypingHoldsFocusOnLastClick() {
        // Click into a field, then type. The anchor should stay on the click point
        // even though the cursor is elsewhere (text-input tracking).
        let clicks = [ClickSample(t: 1.0, x: 0.2, y: 0.8, button: "left")]
        let keys = [KeySample(t: 1.2, keyCode: 0, chars: "h", modifiers: [])]
        let cursor = [CursorSample(t: 0, x: 0.9, y: 0.1), CursorSample(t: 2, x: 0.9, y: 0.1)]
        let ft = FocusTimeline(metadata: meta(cursor: cursor, clicks: clicks, keys: keys), maxZoom: 2.0)
        let target = ft.target(at: 1.3)
        // Center should be pulled toward the click (0.2, 0.8), not the cursor (0.9, 0.1).
        XCTAssertLessThan(target.cx, 0.5)
        XCTAssertGreaterThan(target.cy, 0.5)
    }

    // MARK: - Cursor interpolation

    func testCursorInterpolatesLinearly() {
        let cursor = [CursorSample(t: 0, x: 0, y: 0), CursorSample(t: 2, x: 1, y: 1)]
        let ft = FocusTimeline(metadata: meta(cursor: cursor))
        let p = ft.cursorPoint(at: 1.0)   // midpoint
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
    }

    func testCursorClampsToEndpoints() {
        let cursor = [CursorSample(t: 1, x: 0.25, y: 0.75), CursorSample(t: 3, x: 0.8, y: 0.2)]
        let ft = FocusTimeline(metadata: meta(cursor: cursor))
        let before = ft.cursorPoint(at: 0)
        XCTAssertEqual(before.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(before.y, 0.75, accuracy: 1e-9)
        let after = ft.cursorPoint(at: 10)
        XCTAssertEqual(after.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(after.y, 0.2, accuracy: 1e-9)
    }

    func testEmptyCursorDefaultsToCenter() {
        let ft = FocusTimeline(metadata: meta())
        let p = ft.cursorPoint(at: 3)
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
    }

    // MARK: - Shortcut badges

    func testShortcutBadgeShownOnlyForModifiedKeys() {
        let keys = [
            KeySample(t: 1.0, keyCode: 8, chars: "c", modifiers: ["cmd"]),      // ⌘C
            KeySample(t: 3.0, keyCode: 0, chars: "a", modifiers: [])            // plain typing
        ]
        let ft = FocusTimeline(metadata: meta(keys: keys))
        XCTAssertEqual(ft.shortcutBadge(at: 1.05), "⌘C")
        XCTAssertNil(ft.shortcutBadge(at: 3.05), "plain typing should not badge")
    }

    func testShortcutBadgeExpiresAfterWindow() {
        let keys = [KeySample(t: 1.0, keyCode: 8, chars: "c", modifiers: ["cmd"])]
        let ft = FocusTimeline(metadata: meta(keys: keys))
        XCTAssertNil(ft.shortcutBadge(at: 5.0))
    }

    func testBadgeLabelOrdersModifiersAndNamesSpecialKeys() {
        let k = KeySample(t: 0, keyCode: 36, chars: "", modifiers: ["shift", "cmd", "ctrl", "opt"])
        // Order is ⌃⌥⇧⌘, and keyCode 36 is Return.
        XCTAssertEqual(FocusTimeline.badgeLabel(for: k), "⌃⌥⇧⌘↩")
    }
}
