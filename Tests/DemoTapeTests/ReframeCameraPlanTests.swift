import XCTest
import CoreGraphics
@testable import DemoTape

/// The reframe camera's behaviour, written against the specified acceptance criteria: clamping to the
/// source, edge elements landing near the edge, full field height while typing, idle returning to
/// overview, and a far jump routing through overview instead of panning across at high zoom.
final class ReframeCameraPlanTests: XCTestCase {

    private let source = CGSize(width: 1440, height: 738)     // the landscape screen
    private let portrait = CGSize(width: 1080, height: 1920)

    private func metadata(clicks: [(Double, Double, Double)] = [],
                          keys: [(Double, Double?, Double?)] = [],
                          scrolls: [(Double, Double, Double)] = [],
                          duration: Double = 60) -> RecordingMetadata {
        RecordingMetadata(
            version: 1, startedAt: Date(), duration: duration, capturedKeystrokes: true,
            cameraStartOffset: nil, eventTimeOffset: nil,
            display: DisplayInfo(pointWidth: 1440, pointHeight: 738,
                                 pixelWidth: 1440, pixelHeight: 738, scale: 1),
            cursor: [],
            clicks: clicks.map { ClickSample(t: $0.0, x: $0.1, y: $0.2, button: "left") },
            scrolls: scrolls.map { ScrollSample(t: $0.0, x: $0.1, y: $0.2, dx: 0, dy: 40) },
            keys: keys.map { KeySample(t: $0.0, keyCode: 0, chars: "a", modifiers: [], x: $0.1, y: $0.2) })
    }

    private func plan(_ md: RecordingMetadata, zoomMultiplier: CGFloat = 1.0) -> ReframeCameraPlan {
        var p = ReframeCameraPlan.Params()
        p.interactionZoom = ReframeGeometry.fillZoom(source: source, target: portrait) * zoomMultiplier
        return ReframeCameraPlan.build(metadata: md, duration: md.duration, params: p)
    }

    // MARK: - Geometry: the hard invariant

    func testNoFrameEverSamplesOutsideTheSource() {
        // Every zoom, every centre — including centres well outside [0,1] — stays inside the source.
        for zoomStep in stride(from: 0.5, through: 8.0, by: 0.25) {
            for cx in stride(from: -0.5, through: 1.5, by: 0.1) {
                for cy in stride(from: -0.5, through: 1.5, by: 0.25) {
                    let v = ReframeGeometry.view(zoom: CGFloat(zoomStep),
                                                 center: CGPoint(x: cx, y: cy),
                                                 source: source, target: portrait)
                    XCTAssertGreaterThanOrEqual(v.rect.minX, 0)
                    XCTAssertGreaterThanOrEqual(v.rect.minY, 0)
                    XCTAssertLessThanOrEqual(v.rect.maxX, source.width)
                    XCTAssertLessThanOrEqual(v.rect.maxY, source.height)
                }
            }
        }
    }

    func testFarRightClickStopsAtTheRightEdgeInsteadOfCentring() {
        let fill = ReframeGeometry.fillZoom(source: source, target: portrait)
        let v = ReframeGeometry.view(zoom: fill, center: CGPoint(x: 0.98, y: 0.5),
                                     source: source, target: portrait)
        // The camera slid right until its right edge met the source's, and stopped there.
        XCTAssertEqual(v.rect.maxX, source.width, accuracy: 1)
        // So the element is NOT centred — it sits right of the frame's middle.
        let elementX = 0.98 * source.width
        XCTAssertGreaterThan(elementX, v.rect.midX)
        XCTAssertLessThanOrEqual(elementX, v.rect.maxX)
    }

    func testFarLeftClickStopsAtTheLeftEdge() {
        let fill = ReframeGeometry.fillZoom(source: source, target: portrait)
        let v = ReframeGeometry.view(zoom: fill, center: CGPoint(x: 0.01, y: 0.5),
                                     source: source, target: portrait)
        XCTAssertEqual(v.rect.minX, 0, accuracy: 1)
        XCTAssertLessThan(0.01 * source.width, v.rect.midX)
    }

    func testFillZoomShowsTheFullSourceHeightAndDisablesVerticalPanning() {
        let fill = ReframeGeometry.fillZoom(source: source, target: portrait)
        let v = ReframeGeometry.view(zoom: fill, center: CGPoint(x: 0.5, y: 0.2),
                                     source: source, target: portrait)
        // Full height visible → a text field is always shown with its full height plus padding.
        XCTAssertEqual(v.rect.height, source.height, accuracy: 1)
        XCTAssertTrue(v.verticalPanDisabled)
        // A different cy must not move the rect vertically.
        let other = ReframeGeometry.view(zoom: fill, center: CGPoint(x: 0.5, y: 0.9),
                                         source: source, target: portrait)
        XCTAssertEqual(v.rect.minY, other.rect.minY, accuracy: 0.5)
        // And the frame is filled horizontally (no side bars).
        XCTAssertEqual(v.rect.width * v.scale, portrait.width, accuracy: 2)
    }

    func testOverviewLetterboxesAndDisablesVerticalPanning() {
        let v = ReframeGeometry.view(zoom: 1, center: CGPoint(x: 0.5, y: 0.5),
                                     source: source, target: portrait)
        XCTAssertEqual(v.rect.width, source.width, accuracy: 1)    // whole width
        XCTAssertTrue(v.verticalPanDisabled)
        XCTAssertGreaterThan(v.offsetY, 0)                          // letterboxed remainder
    }

    func testAboveFillZoomVerticalPanningIsEnabled() {
        let fill = ReframeGeometry.fillZoom(source: source, target: portrait)
        let high = ReframeGeometry.view(zoom: fill * 1.6, center: CGPoint(x: 0.5, y: 0.25),
                                        source: source, target: portrait)
        XCTAssertFalse(high.verticalPanDisabled)
        let low = ReframeGeometry.view(zoom: fill * 1.6, center: CGPoint(x: 0.5, y: 0.75),
                                       source: source, target: portrait)
        XCTAssertGreaterThan(low.rect.minY, high.rect.minY)         // it did pan vertically
    }

    // MARK: - Motion

    func testCameraNeverTeleports() {
        // Two far-apart clicks: sample densely and assert no single frame jumps a large distance.
        let md = metadata(clicks: [(3, 0.08, 0.5), (12, 0.92, 0.5)])
        let p = plan(md)
        var previous = p.state(at: 0)
        var maxStep: CGFloat = 0
        for t in stride(from: 0.0, through: 20.0, by: 1.0 / 30.0) {
            let s = p.state(at: t)
            maxStep = max(maxStep, abs(s.cx - previous.cx))
            previous = s
        }
        // At 30fps a 600ms eased move covers ~1.0 of width at most a few % per frame.
        XCTAssertLessThan(maxStep, 0.06, "camera jumped \(maxStep) of the width in one frame")
    }

    func testCameraArrivesByTheInteractionMoment() {
        let md = metadata(clicks: [(8.0, 0.8, 0.5)])
        let p = plan(md)
        let atClick = p.state(at: 8.0)
        XCTAssertFalse(atClick.isOverview, "the camera should have arrived when the click lands")
        XCTAssertEqual(atClick.cx, 0.8, accuracy: 0.02)
        // And it was still on its way slightly earlier (anticipation, not a jump at the moment).
        let before = p.state(at: 7.7)
        XCTAssertNotEqual(before.zoom, atClick.zoom, accuracy: 0.001)
    }

    func testNearbyClicksHoldTheCameraInsteadOfMicroAdjusting() {
        // Three clicks within 15% of the width, close in time → one held shot.
        let md = metadata(clicks: [(5.0, 0.50, 0.5), (5.9, 0.55, 0.52), (6.7, 0.58, 0.5)])
        let p = plan(md)
        let a = p.state(at: 5.0), b = p.state(at: 6.0), c = p.state(at: 6.9)
        XCTAssertEqual(a.cx, b.cx, accuracy: 0.01)
        XCTAssertEqual(b.cx, c.cx, accuracy: 0.01)
    }

    func testIdleReturnsToOverview() {
        let md = metadata(clicks: [(3.0, 0.3, 0.5)], duration: 30)
        let p = plan(md)
        XCTAssertFalse(p.state(at: 3.0).isOverview)
        XCTAssertTrue(p.state(at: 12.0).isOverview, "after a long idle the camera should be at overview")
    }

    func testDistantPanRoutesThroughOverview() {
        // Left click then right click, far apart: the camera must zoom out in between, not slide across.
        let md = metadata(clicks: [(4.0, 0.10, 0.5), (7.0, 0.90, 0.5)])
        let p = plan(md)
        var minZoom = CGFloat.greatestFiniteMagnitude
        for t in stride(from: 4.0, through: 7.0, by: 0.05) { minZoom = min(minZoom, p.state(at: t).zoom) }
        XCTAssertEqual(minZoom, 1, accuracy: 0.05, "the move should pass through overview (zoom 1)")
        // Both ends are still proper shots.
        XCTAssertFalse(p.state(at: 4.0).isOverview)
        XCTAssertFalse(p.state(at: 7.0).isOverview)
    }

    func testShortPanDoesNotZoomOut() {
        let md = metadata(clicks: [(4.0, 0.40, 0.5), (7.0, 0.62, 0.5)])
        let p = plan(md)
        var minZoom = CGFloat.greatestFiniteMagnitude
        for t in stride(from: 4.0, through: 7.0, by: 0.05) { minZoom = min(minZoom, p.state(at: t).zoom) }
        XCTAssertGreaterThan(minZoom, 1.2, "a nearby move should stay zoomed in")
    }

    func testFastScrollingReturnsToOverview() {
        let scrolls = (0..<10).map { (10.0 + Double($0) * 0.05, 0.5, 0.5) }
        let md = metadata(clicks: [(3.0, 0.3, 0.5)], scrolls: scrolls, duration: 40)
        let p = plan(md)
        XCTAssertTrue(p.state(at: 10.3).isOverview, "fast scrolling should sit at overview")
    }

    // MARK: - Typing

    /// A run of keystrokes whose caret advances rightward from x=0.10, as a driver would report.
    private func typingRun(count: Int, step: Double = 0.012,
                           interval: Double = 0.12) -> [(Double, Double?, Double?)] {
        var out: [(Double, Double?, Double?)] = []
        for i in 0..<count {
            out.append((9.0 + Double(i) * interval, 0.10 + Double(i) * step, 0.9))
        }
        return out
    }

    func testTypingFramesTextLeftAlignedSoItGrowsIntoFrame() {
        let keys = typingRun(count: 40)
        let md = metadata(clicks: [(8.5, 0.10, 0.9)], keys: keys, duration: 40)
        let p = plan(md)
        let window = 1 / p.params.interactionZoom

        // At the start of the run the caret sits near the LEFT of the window: the text has the rest of
        // the window to grow into, rather than the window being centred on the caret.
        let start = p.state(at: 9.2)
        let caretStart: CGFloat = 0.10
        let offsetInWindow = (caretStart - (start.cx - window / 2)) / window
        XCTAssertLessThan(offsetInWindow, 0.35, "the caret should start near the left of the window")
        XCTAssertGreaterThanOrEqual(offsetInWindow, -0.01)
    }

    func testTypingKeepsTheCaretInFrameThroughoutTheRun() {
        let keys = typingRun(count: 60, interval: 0.1)
        let md = metadata(clicks: [(8.5, 0.10, 0.9)], keys: keys, duration: 40)
        let p = plan(md)
        let window = 1 / p.params.interactionZoom
        // Sample every keystroke moment: the caret must be inside the visible window.
        for k in keys {
            let s = p.state(at: k.0)
            let left = s.cx - window / 2, right = s.cx + window / 2
            let caret = CGFloat(k.1 ?? 0)
            // Allow the clamped edges of the source (the window can't go past x=1).
            XCTAssertTrue(caret >= left - 0.02 && caret <= right + 0.02,
                          "caret \(caret) outside window [\(left), \(right)] at t=\(k.0)")
        }
    }

    func testTypingPansForwardMonotonicallyAndSmoothly() {
        let keys = typingRun(count: 60, interval: 0.1)
        let md = metadata(clicks: [(8.5, 0.10, 0.9)], keys: keys, duration: 40)
        let p = plan(md)
        var previous = p.state(at: 9.0).cx
        var maxStep: CGFloat = 0
        for t in stride(from: 9.0, through: 15.0, by: 1.0 / 30.0) {
            let cx = p.state(at: t).cx
            maxStep = max(maxStep, abs(cx - previous))
            previous = cx
        }
        XCTAssertLessThan(maxStep, 0.03, "the typing pan should be gradual, not a jump")
    }

    func testPlanAlwaysStartsAtOverview() {
        let p = plan(metadata(clicks: [(6.0, 0.5, 0.5)]))
        XCTAssertTrue(p.state(at: 0).isOverview)
    }

    func testEmptyTimelineStaysAtOverview() {
        let p = plan(metadata())
        XCTAssertTrue(p.state(at: 0).isOverview)
        XCTAssertTrue(p.state(at: 25).isOverview)
    }
}
