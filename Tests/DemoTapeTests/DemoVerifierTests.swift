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

// MARK: - Token budget
//
// The gate's real constraint is tokens per minute, not requests per minute: a screenshot costs
// thousands of tokens and the small vision models charge each tile many times over. These pin the
// arithmetic that decides how far apart the scene checks have to be.

extension DemoVerifierTests {

    func testImageTilesCoversTheScaledImage() {
        // A 768-tall widescreen frame is three tiles across and two down.
        XCTAssertEqual(DemoVerifier.imageTiles(width: 1229, height: 768), 6)
        // Small enough for a single tile.
        XCTAssertEqual(DemoVerifier.imageTiles(width: 500, height: 300), 1)
        // Oversized input is scaled down first, so tiles stay bounded.
        XCTAssertEqual(DemoVerifier.imageTiles(width: 4000, height: 2500), 6)
        XCTAssertEqual(DemoVerifier.imageTiles(width: 0, height: 0), 1)
    }

    func testMiniModelsCostFarMoreForTheSameImage() {
        let mini = DemoVerifier.estimatedImageTokens(width: 1229, height: 768, model: "gpt-4o-mini")
        let full = DemoVerifier.estimatedImageTokens(width: 1229, height: 768, model: "gpt-4o")
        XCTAssertGreaterThan(mini, 30_000)          // this is what exhausts a 200k budget in 6 scenes
        XCTAssertLessThan(full, 1_500)
        XCTAssertGreaterThan(mini, full * 20)
    }

    func testPacingSpreadsTheBudgetOverAMinute() {
        // ~37k tokens a scene against 200k a minute is about eleven seconds apart.
        let gap = DemoVerifier.pacingSeconds(tokensPerScene: 36_835, budgetTPM: 200_000)
        XCTAssertEqual(gap, 11.05, accuracy: 0.05)
        // A cheap frame needs no real pacing.
        XCTAssertLessThan(DemoVerifier.pacingSeconds(tokensPerScene: 900, budgetTPM: 200_000), 0.3)
    }

    func testPacingDisabledWithoutABudget() {
        XCTAssertEqual(DemoVerifier.pacingSeconds(tokensPerScene: 36_835, budgetTPM: 0), 0)
        XCTAssertEqual(DemoVerifier.pacingSeconds(tokensPerScene: 0, budgetTPM: 200_000), 0)
    }
}
