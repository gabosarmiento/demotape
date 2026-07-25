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

/// `demotape://ui/…` — lets a scripted walkthrough open DemoTape's own windows, since a menu row's
/// screen rect isn't discoverable from outside the app.
extension DemoControlTests {

    func testParseOpenUIByQuery() {
        let url = URL(string: "demotape://ui/open?window=publish")!
        XCTAssertEqual(DemoControl.parse(url), .openUI(.publish))
    }

    func testParseOpenUIShorthandPath() {
        let url = URL(string: "demotape://ui/about")!
        XCTAssertEqual(DemoControl.parse(url), .openUI(.about))
    }

    func testParseOpenUIIsCaseInsensitive() {
        let url = URL(string: "demotape://ui/open?window=COMPOSER")!
        XCTAssertEqual(DemoControl.parse(url), .openUI(.composer))
    }

    func testParseOpenUIRejectsUnknownWindow() {
        let url = URL(string: "demotape://ui/open?window=nope")!
        XCTAssertNil(DemoControl.parse(url))
    }

    func testEveryWindowCaseParses() {
        for w in DemoControl.Window.allCases {
            let url = URL(string: "demotape://ui/open?window=\(w.rawValue)")!
            XCTAssertEqual(DemoControl.parse(url), .openUI(w), "failed for \(w.rawValue)")
        }
    }
}

/// Cursor glide — animated, human-looking travel instead of a teleport.
extension DemoControlTests {

    func testPlainCursorDoesNotGlide() {
        let url = URL(string: "demotape://cursor?x=100&y=200")!
        XCTAssertEqual(DemoControl.parse(url), .cursor(x: 100, y: 200, click: false, glideMs: 0))
    }

    func testGlidePathGetsDefaultDuration() {
        let url = URL(string: "demotape://cursor/glide?x=100&y=200")!
        XCTAssertEqual(DemoControl.parse(url), .cursor(x: 100, y: 200, click: false, glideMs: 420))
    }

    func testExplicitMsOverridesGlideDefault() {
        let url = URL(string: "demotape://cursor/glide?x=10&y=20&ms=900")!
        XCTAssertEqual(DemoControl.parse(url), .cursor(x: 10, y: 20, click: false, glideMs: 900))
    }

    func testMsWorksWithoutGlidePathSegment() {
        let url = URL(string: "demotape://cursor?x=10&y=20&ms=250")!
        XCTAssertEqual(DemoControl.parse(url), .cursor(x: 10, y: 20, click: false, glideMs: 250))
    }

    func testGlideAndClickCombine() {
        let url = URL(string: "demotape://cursor/glide/click?x=5&y=6&ms=300")!
        XCTAssertEqual(DemoControl.parse(url), .cursor(x: 5, y: 6, click: true, glideMs: 300))
    }

    func testNegativeDurationIsClampedToZero() {
        let url = URL(string: "demotape://cursor?x=1&y=2&ms=-500")!
        XCTAssertEqual(DemoControl.parse(url), .cursor(x: 1, y: 2, click: false, glideMs: 0))
    }

    func testCursorStillRequiresBothCoordinates() {
        XCTAssertNil(DemoControl.parse(URL(string: "demotape://cursor/glide?x=10")!))
    }
}

/// Semantic (coordinate-free) targeting through the control surface.
extension DemoControlTests {

    func testParseElementClickByLabel() {
        let url = URL(string: "demotape://ui/click?label=Export")!
        XCTAssertEqual(DemoControl.parse(url),
                       .element(query: .init(label: "Export"), click: true))
    }

    func testParseElementFindDoesNotClick() {
        let url = URL(string: "demotape://ui/find?label=Export")!
        XCTAssertEqual(DemoControl.parse(url),
                       .element(query: .init(label: "Export"), click: false))
    }

    func testParseElementCarriesRoleAppAndIndex() {
        let url = URL(string: "demotape://ui/click?label=Allow&role=AXButton&app=Safari&index=2")!
        XCTAssertEqual(DemoControl.parse(url),
                       .element(query: .init(label: "Allow", role: "AXButton",
                                             app: "Safari", index: 2), click: true))
    }

    func testParseElementRequiresALabel() {
        XCTAssertNil(DemoControl.parse(URL(string: "demotape://ui/click?role=AXButton")!))
    }

    func testParseDumpUI() {
        XCTAssertEqual(DemoControl.parse(URL(string: "demotape://ui/dump")!), .dumpUI(app: nil))
        XCTAssertEqual(DemoControl.parse(URL(string: "demotape://ui/dump?app=Safari")!),
                       .dumpUI(app: "Safari"))
    }
}

/// `+` in a query value means a space — scripts build these URLs by hand.
extension DemoControlTests {

    func testPlusIsDecodedAsSpaceInLabels() {
        let url = URL(string: "demotape://ui/click?label=Check+for+Updates")!
        XCTAssertEqual(DemoControl.parse(url),
                       .element(query: .init(label: "Check for Updates"), click: true))
    }

    func testPercentEncodedSpacesStillWork() {
        let url = URL(string: "demotape://ui/click?label=Check%20for%20Updates")!
        XCTAssertEqual(DemoControl.parse(url),
                       .element(query: .init(label: "Check for Updates"), click: true))
    }

    func testPlusDecodingAppliesToAppNames() {
        let url = URL(string: "demotape://ui/dump?app=Visual+Studio+Code")!
        XCTAssertEqual(DemoControl.parse(url), .dumpUI(app: "Visual Studio Code"))
    }
}

/// The menu must be told how long to stay open: while it tracks, it blocks every later command.
extension DemoControlTests {

    func testMenuHoldIsParsed() {
        let url = URL(string: "demotape://ui/open?window=menu&hold=2500")!
        XCTAssertEqual(DemoControl.parse(url), .openUI(.menu, holdMs: 2500))
    }

    func testHoldDefaultsToZeroMeaningNoAutoDismiss() {
        let url = URL(string: "demotape://ui/open?window=menu")!
        XCTAssertEqual(DemoControl.parse(url), .openUI(.menu, holdMs: 0))
    }

    func testNegativeHoldIsClamped() {
        let url = URL(string: "demotape://ui/open?window=menu&hold=-400")!
        XCTAssertEqual(DemoControl.parse(url), .openUI(.menu, holdMs: 0))
    }
}

/// Real OS typing. Auto-zoom is driven by clicks AND keys, so typing the app can't observe leaves
/// the camera wide while text appears.
extension DemoControlTests {

    func testParseTypeText() {
        let url = URL(string: "demotape://type?text=hello%20world")!
        XCTAssertEqual(DemoControl.parse(url), .type(text: "hello world", cps: 0, expectedApp: nil))
    }

    func testParseTypeWithRate() {
        let url = URL(string: "demotape://type?text=abc&cps=12.5")!
        XCTAssertEqual(DemoControl.parse(url), .type(text: "abc", cps: 12.5, expectedApp: nil))
    }

    func testParseTypeDecodesPlusAsSpace() {
        let url = URL(string: "demotape://type?text=roll+it+back")!
        XCTAssertEqual(DemoControl.parse(url), .type(text: "roll it back", cps: 0, expectedApp: nil))
    }

    func testParseTypeRequiresText() {
        XCTAssertNil(DemoControl.parse(URL(string: "demotape://type?cps=10")!))
        XCTAssertNil(DemoControl.parse(URL(string: "demotape://type?text=")!))
    }

    func testParseTypeClampsNegativeRate() {
        let url = URL(string: "demotape://type?text=abc&cps=-5")!
        XCTAssertEqual(DemoControl.parse(url), .type(text: "abc", cps: 0, expectedApp: nil))
    }
}

/// Typing ACTIVITY — records the zoom hold without posting keystrokes, for text a browser
/// automation tool types itself (browsers drop synthetic keys that carry no virtual keycode).
extension DemoControlTests {

    func testParseTypingActivity() {
        let url = URL(string: "demotape://typing?chars=42&cps=14")!
        XCTAssertEqual(DemoControl.parse(url), .typingActivity(chars: 42, cps: 14))
    }

    func testTypingActivityRateIsOptional() {
        let url = URL(string: "demotape://typing?chars=8")!
        XCTAssertEqual(DemoControl.parse(url), .typingActivity(chars: 8, cps: 0))
    }

    func testTypingActivityRequiresPositiveCount() {
        XCTAssertNil(DemoControl.parse(URL(string: "demotape://typing?chars=0")!))
        XCTAssertNil(DemoControl.parse(URL(string: "demotape://typing?cps=14")!))
    }

    /// `typing` (activity) and `type` (real keystrokes) must stay distinct commands.
    func testTypingActivityIsNotConfusedWithRealTyping() {
        XCTAssertEqual(DemoControl.parse(URL(string: "demotape://type?text=hi")!),
                       .type(text: "hi", cps: 0, expectedApp: nil))
        XCTAssertEqual(DemoControl.parse(URL(string: "demotape://typing?chars=2")!),
                       .typingActivity(chars: 2, cps: 0))
    }
}

/// The `app=` guard on real OS typing. Keystrokes follow SYSTEM focus, so a caller must be able to
/// say which app it expects to be frontmost — otherwise a mis-timed command types into the user's
/// editor, destructively and silently.
extension DemoControlTests {

    func testTypeCarriesExpectedApp() {
        let url = URL(string: "demotape://type?text=hi&app=Chromium")!
        XCTAssertEqual(DemoControl.parse(url), .type(text: "hi", cps: 0, expectedApp: "Chromium"))
    }

    func testExpectedAppSurvivesPlusDecoding() {
        let url = URL(string: "demotape://type?text=hi&app=Google+Chrome")!
        XCTAssertEqual(DemoControl.parse(url),
                       .type(text: "hi", cps: 0, expectedApp: "Google Chrome"))
    }

    func testExpectedAppIsOptional() {
        let url = URL(string: "demotape://type?text=hi")!
        XCTAssertEqual(DemoControl.parse(url), .type(text: "hi", cps: 0, expectedApp: nil))
    }
}
