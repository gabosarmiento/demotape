import XCTest
@testable import DemoTape

final class DemoVerifierTests: XCTestCase {

    func testParseVerdictAcceptsPassAndFail() {
        XCTAssertEqual(DemoVerifier.parseVerdict("{\"verdict\":\"pass\",\"reason\":\"looks right\"}").verdict, "pass")
        XCTAssertEqual(DemoVerifier.parseVerdict("```json\n{\"verdict\":\"fail\",\"reason\":\"error page\"}\n```").verdict, "fail")
    }

    func testParseVerdictReason() {
        XCTAssertEqual(DemoVerifier.parseVerdict("{\"verdict\":\"fail\",\"reason\":\"blank screen\"}").reason, "blank screen")
    }

    func testParseVerdictTreatsGarbageAsFail() {
        XCTAssertEqual(DemoVerifier.parseVerdict("not json").verdict, "fail", "unverifiable must fail closed")
        XCTAssertEqual(DemoVerifier.parseVerdict("{\"nope\":1}").verdict, "fail")
    }

    func testOverallPassRequiresEveryScene() {
        let ok = [DemoVerifier.Result(at: 0, say: "a", verdict: "pass", reason: ""),
                  DemoVerifier.Result(at: 3, say: "b", verdict: "pass", reason: "")]
        let bad = [DemoVerifier.Result(at: 0, say: "a", verdict: "pass", reason: ""),
                   DemoVerifier.Result(at: 3, say: "b", verdict: "fail", reason: "wrong page")]
        XCTAssertTrue(DemoVerifier.overallPass(ok))
        XCTAssertFalse(DemoVerifier.overallPass(bad))
        XCTAssertFalse(DemoVerifier.overallPass([]), "no scenes is not a pass")
    }
}
