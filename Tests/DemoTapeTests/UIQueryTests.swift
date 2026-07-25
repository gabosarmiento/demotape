import XCTest
@testable import DemoTape

/// Pure matching/resolution logic for semantic UI targeting — no AX calls, no AppKit, no screen.
final class UIQueryTests: XCTestCase {

    private func el(_ label: String, _ role: String = "AXButton",
                    x: CGFloat = 0, y: CGFloat = 0) -> UIQuery.Element {
        UIQuery.Element(role: role, label: label,
                        frame: CGRect(x: x, y: y, width: 100, height: 24))
    }

    // MARK: - Label normalisation

    func testNormaliseFoldsCaseAndTrims() {
        XCTAssertEqual(UIQuery.normalise("  Export CSV  "), "export csv")
    }

    func testNormaliseStripsTrailingEllipsisCharacter() {
        XCTAssertEqual(UIQuery.normalise("Add Captions…"), "add captions")
    }

    func testNormaliseStripsThreeDotEllipsis() {
        XCTAssertEqual(UIQuery.normalise("Add Captions..."), "add captions")
    }

    // MARK: - Matching

    func testMatchIgnoresEllipsisSoActionsAreAddressable() {
        XCTAssertTrue(UIQuery.matches(el("Add Captions…"), .init(label: "Add Captions")))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(UIQuery.matches(el("Star on GitHub"), .init(label: "star on github")))
    }

    func testMatchSupportsPartialLabels() {
        XCTAssertTrue(UIQuery.matches(el("★ Star on GitHub"), .init(label: "star")))
    }

    func testRoleFilterExcludesWrongRole() {
        let q = UIQuery.Query(label: "Export", role: "AXButton")
        XCTAssertFalse(UIQuery.matches(el("Export", "AXStaticText"), q))
        XCTAssertTrue(UIQuery.matches(el("Export", "AXButton"), q))
    }

    func testEmptyLabelNeverMatches() {
        XCTAssertFalse(UIQuery.matches(el("Export"), .init(label: "   ")))
    }

    // MARK: - Resolution

    func testExactMatchBeatsPartialMatch() {
        // "Export CSV" also contains "export", but a real "Export" button must win.
        let found = UIQuery.resolve([el("Export CSV"), el("Export")], .init(label: "Export"))
        XCTAssertEqual(found?.label, "Export")
    }

    func testIndexPicksAmongEqualLabels() {
        let a = el("Allow…", x: 10)
        let b = el("Allow…", x: 200)
        XCTAssertEqual(UIQuery.resolve([a, b], .init(label: "Allow", index: 1))?.frame.minX, 200)
    }

    func testMissReturnsNilRatherThanAFallback() {
        XCTAssertNil(UIQuery.resolve([el("Export")], .init(label: "Publish")))
    }

    func testOutOfRangeIndexReturnsNil() {
        XCTAssertNil(UIQuery.resolve([el("Export")], .init(label: "Export", index: 3)))
    }

    func testCentreIsTheMiddleOfTheFrame() {
        let e = UIQuery.Element(role: "AXButton", label: "Go",
                               frame: CGRect(x: 100, y: 200, width: 80, height: 40))
        XCTAssertEqual(e.centre, CGPoint(x: 140, y: 220))
    }
}
