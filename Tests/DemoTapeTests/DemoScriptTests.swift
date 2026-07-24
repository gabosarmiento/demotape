import XCTest
@testable import DemoTape

final class DemoScriptTests: XCTestCase {

    func testWordBudgetScalesWithDuration() {
        XCTAssertEqual(DemoScript.approxWordBudget(seconds: 60), 150)
        XCTAssertEqual(DemoScript.approxWordBudget(seconds: 120), 300)
        XCTAssertGreaterThanOrEqual(DemoScript.approxWordBudget(seconds: 5), 30) // floor
    }

    func testPromptIncludesIdeaPathDurationAndSteps() {
        let p = DemoScript.kiroPrompt(idea: "Show how the dashboard works",
                                      projectPath: "/Users/me/kiff-cloud",
                                      targetSeconds: 90, voiceId: "abc123")
        XCTAssertTrue(p.contains("Show how the dashboard works"))
        XCTAssertTrue(p.contains("/Users/me/kiff-cloud"))
        XCTAssertTrue(p.contains("1:30"))
        XCTAssertTrue(p.contains("demo-driver"))
        XCTAssertTrue(p.contains("scenes"))
        XCTAssertTrue(p.contains("driver.mjs"))
        XCTAssertTrue(p.contains("abc123"), "uses the supplied voice id")
    }

    func testPromptFallsBackWhenIdeaAndVoiceEmpty() {
        let p = DemoScript.kiroPrompt(idea: "   ", projectPath: "", targetSeconds: 60, voiceId: nil)
        XCTAssertTrue(p.contains("a short product demo of this project"))
        XCTAssertTrue(p.contains("the current workspace"))
        XCTAssertTrue(p.contains("--voices"), "prompts the agent to pick a voice when none given")
    }
}
