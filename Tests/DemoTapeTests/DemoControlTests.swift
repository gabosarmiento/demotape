import XCTest
@testable import DemoTape

final class DemoControlTests: XCTestCase {

    private func parse(_ s: String) -> DemoControl.Command? {
        guard let url = URL(string: s) else { return nil }
        return DemoControl.parse(url)
    }

    func testStopVariants() {
        XCTAssertEqual(parse("demotape://record/stop"), .stop)
        XCTAssertEqual(parse("demotape://stop"), .stop)
        XCTAssertEqual(parse("DEMOTAPE://record/STOP"), .stop)
    }

    func testStartFullScreenDefaults() {
        guard case .start(let opts)? = parse("demotape://record/start") else { return XCTFail() }
        XCTAssertEqual(opts.region, .fullScreen)
        XCTAssertEqual(opts.countdown, 3)
        XCTAssertNil(opts.microphone)
        XCTAssertNil(opts.webcam)
    }

    func testStartImmediate() {
        guard case .start(let opts)? = parse("demotape://record/start?countdown=0") else { return XCTFail() }
        XCTAssertEqual(opts.countdown, 0)
    }

    func testStartNormalizedRegion() {
        guard case .start(let opts)? = parse("demotape://record/start?nx=0.1&ny=0.2&nw=0.5&nh=0.4") else { return XCTFail() }
        XCTAssertEqual(opts.region, .normalized(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)))
    }

    func testStartPixelRegion() {
        guard case .start(let opts)? = parse("demotape://record/start?mode=area&x=100&y=80&w=1280&h=720") else { return XCTFail() }
        XCTAssertEqual(opts.region, .pixels(CGRect(x: 100, y: 80, width: 1280, height: 720)))
    }

    func testStartInputFlags() {
        guard case .start(let opts)? = parse("demotape://record/start?mic=1&webcam=0") else { return XCTFail() }
        XCTAssertEqual(opts.microphone, true)
        XCTAssertEqual(opts.webcam, false)
    }

    func testNormalizedTakesPrecedenceOverPixels() {
        guard case .start(let opts)? = parse("demotape://record/start?nx=0&ny=0&nw=1&nh=1&x=5&y=5&w=5&h=5") else { return XCTFail() }
        XCTAssertEqual(opts.region, .normalized(CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    func testRejectsForeignSchemeAndGarbage() {
        XCTAssertNil(parse("https://record/start"))
        XCTAssertNil(parse("demotape://record/pause"))
        XCTAssertNil(parse("demotape://"))
    }

    func testCursorMove() {
        XCTAssertEqual(parse("demotape://cursor/move?x=640&y=360"),
                       .cursor(x: 640, y: 360, click: false))
    }

    func testCursorClick() {
        XCTAssertEqual(parse("demotape://cursor/click?x=12&y=34"),
                       .cursor(x: 12, y: 34, click: true))
    }

    func testCursorRequiresCoordinates() {
        XCTAssertNil(parse("demotape://cursor/click"))
        XCTAssertNil(parse("demotape://cursor/move?x=10"))
    }
}
