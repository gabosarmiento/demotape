import XCTest
@testable import DemoTape

final class AIBriefTests: XCTestCase {

    private func metadata(duration: Double, clicks: [Double] = [], keys: [Double] = [], scrolls: [Double] = []) -> RecordingMetadata {
        RecordingMetadata(
            startedAt: Date(), duration: duration, capturedKeystrokes: true,
            cameraStartOffset: 0, eventTimeOffset: 0,
            display: DisplayInfo(pointWidth: 1440, pointHeight: 900, pixelWidth: 2880, pixelHeight: 1800, scale: 2),
            cursor: [],
            clicks: clicks.map { ClickSample(t: $0, x: 0.5, y: 0.5, button: "left") },
            scrolls: scrolls.map { ScrollSample(t: $0, x: 0.5, y: 0.5, dx: 0, dy: 1) },
            keys: keys.map { KeySample(t: $0, keyCode: 0, chars: "a", modifiers: []) })
    }

    // MARK: - Keyframe selection

    func testKeyframeTimestampsRespectMinGapAndCap() {
        // Many clustered clicks should collapse to a handful of well-spaced frames.
        let md = metadata(duration: 60, clicks: Array(stride(from: 1.0, to: 30.0, by: 0.5)))
        let times = AIBrief.keyframeTimestamps(metadata: md, cues: [], maxFrames: 6, minGap: 1.5)
        XCTAssertLessThanOrEqual(times.count, 6)
        XCTAssertEqual(times, times.sorted(), "timestamps are sorted")
        for i in 1..<times.count {
            XCTAssertGreaterThanOrEqual(times[i] - times[i - 1], 1.5 - 0.0001, "spaced by at least minGap")
        }
        XCTAssertTrue(times.allSatisfy { $0 >= 0 && $0 <= 60 }, "clamped to the recording")
    }

    func testKeyframeTimestampsIncludeOpeningFrame() {
        let md = metadata(duration: 30, clicks: [10])
        let times = AIBrief.keyframeTimestamps(metadata: md, cues: [])
        XCTAssertEqual(times.first, 0.0, "always opens with a frame at t=0")
    }

    func testFrameFilenameIsSortableZeroPadded() {
        XCTAssertEqual(AIBrief.frameFilename(forTimestamp: 7.2), "0007s.png")
        XCTAssertEqual(AIBrief.frameFilename(forTimestamp: 0), "0000s.png")
        XCTAssertEqual(AIBrief.frameFilename(forTimestamp: 123.9), "0124s.png")
    }

    // MARK: - Timeline text

    func testTimelineTextInterleavesAndLabelsActivity() {
        let md = metadata(duration: 20, clicks: [3.0], keys: [3.2], scrolls: [8.0])
        let cues = [CaptionCue(start: 1.0, end: 2.0, text: "Here is the bug"),
                    CaptionCue(start: 9.0, end: 10.0, text: "See how it fails")]
        let text = AIBrief.timelineText(metadata: md, cues: cues)
        XCTAssertTrue(text.contains("SAY: Here is the bug"))
        XCTAssertTrue(text.contains("DO: click+typing"), "same-second click+typing are merged")
        XCTAssertTrue(text.contains("DO: scroll"))
        let sayIdx = text.range(of: "Here is the bug")!.lowerBound
        let doIdx = text.range(of: "DO:")!.lowerBound
        XCTAssertLessThan(sayIdx, doIdx, "ordered by time")
    }

    // MARK: - Intent mapping

    func testIntentMappingIsTolerant() {
        XCTAssertEqual(AIBrief.Intent.from("bug"), .bug)
        XCTAssertEqual(AIBrief.Intent.from("It's broken / crashes"), .bug)
        XCTAssertEqual(AIBrief.Intent.from("feature request"), .change)
        XCTAssertEqual(AIBrief.Intent.from("current behavior"), .behavior)
        XCTAssertEqual(AIBrief.Intent.from("a question"), .question)
        XCTAssertEqual(AIBrief.Intent.from(nil), .other)
        XCTAssertEqual(AIBrief.Intent.from("random noise"), .other)
    }

    // MARK: - Response parsing

    func testParseBriefToleratesFencesAndAttachesFrameNotes() {
        let frames = [AIBrief.Frame(t: 0, filename: "0000s.png", note: nil),
                      AIBrief.Frame(t: 5, filename: "0005s.png", note: nil)]
        let content = """
        Here you go:
        ```json
        {
          "title": "Save button does nothing",
          "intent": "bug",
          "summary": "Clicking Save shows no confirmation and the row is not persisted.",
          "observed": "Nothing happens after clicking Save.",
          "expected": "The row should be saved and a toast shown.",
          "steps": ["Open the editor", "Click Save"],
          "questions": ["Is there a network error in the console?"],
          "frameNotes": ["The editor with an unsaved row", "After clicking Save, still no toast"]
        }
        ```
        """
        guard let brief = AIBrief.parseBrief(fromContent: content, frames: frames) else {
            return XCTFail("expected a parsed brief")
        }
        XCTAssertEqual(brief.title, "Save button does nothing")
        XCTAssertEqual(brief.intent, .bug)
        XCTAssertEqual(brief.steps.count, 2)
        XCTAssertEqual(brief.questions.count, 1)
        XCTAssertEqual(brief.frames[0].note, "The editor with an unsaved row")
        XCTAssertEqual(brief.frames[1].note, "After clicking Save, still no toast")
    }

    func testParseBriefReturnsNilOnGarbage() {
        XCTAssertNil(AIBrief.parseBrief(fromContent: "no json here", frames: []))
    }

    func testParseFrameNotesAndAttachByOrder() {
        let frames = [AIBrief.Frame(t: 0, filename: "0000s.png", note: nil),
                      AIBrief.Frame(t: 5, filename: "0005s.png", note: nil)]
        let notes = AIBrief.parseFrameNotes(fromContent: "```json\n{\"frameNotes\":[\"first shot\",\"second shot\"]}\n```")
        XCTAssertEqual(notes, ["first shot", "second shot"])
        let attached = AIBrief.attachNotes(notes, to: frames)
        XCTAssertEqual(attached[0].note, "first shot")
        XCTAssertEqual(attached[1].note, "second shot")
    }

    func testParseFrameNotesReturnsEmptyOnGarbage() {
        XCTAssertTrue(AIBrief.parseFrameNotes(fromContent: "no json").isEmpty)
    }

    func testParseBriefFillsDefaultsForMissingFields() {
        let brief = AIBrief.parseBrief(fromContent: "{\"summary\":\"just a note\"}", frames: [])
        XCTAssertNotNil(brief)
        XCTAssertFalse(brief!.title.isEmpty, "a title default is supplied")
        XCTAssertEqual(brief!.intent, .other)
        XCTAssertEqual(brief!.summary, "just a note")
        XCTAssertTrue(brief!.steps.isEmpty)
    }

    // MARK: - Output builders

    private func sampleContent() -> AIBrief.Content {
        AIBrief.Content(
            title: "Save button does nothing",
            intent: .bug,
            summary: "Clicking Save does not persist the row.",
            observed: "Nothing happens.",
            expected: "The row is saved.",
            steps: ["Open the editor", "Click Save"],
            questions: ["Any console error?"],
            frames: [AIBrief.Frame(t: 0, filename: "0000s.png", note: "The editor"),
                     AIBrief.Frame(t: 5, filename: "0005s.png", note: "After Save")])
    }

    func testBriefMarkdownIncludesSectionsAndFrameRefs() {
        let md = AIBrief.briefMarkdown(sampleContent(), sourceName: "clip.mov", duration: 65)
        XCTAssertTrue(md.contains("# Save button does nothing"))
        XCTAssertTrue(md.contains("**Type:** Bug"))
        XCTAssertTrue(md.contains("clip.mov · 1:05"))
        XCTAssertTrue(md.contains("## Observed"))
        XCTAssertTrue(md.contains("## Expected"))
        XCTAssertTrue(md.contains("1. Open the editor"))
        XCTAssertTrue(md.contains("`frames/0000s.png` (0:00) — The editor"))
        XCTAssertTrue(md.contains("## Open questions"))
        XCTAssertTrue(md.contains("transcript.srt"))
    }

    func testBriefMarkdownOmitsEmptySections() {
        var c = sampleContent()
        c.observed = ""; c.expected = ""; c.questions = []
        let md = AIBrief.briefMarkdown(c, sourceName: "clip.mov", duration: 10)
        XCTAssertFalse(md.contains("## Observed"))
        XCTAssertFalse(md.contains("## Expected"))
        XCTAssertFalse(md.contains("## Open questions"))
        XCTAssertTrue(md.contains("## Summary"))
    }

    func testAgentPromptReferencesFolderPathAndAgentReadsFiles() {
        let prompt = AIBrief.handoffPrompt(sampleContent(), bundleDirPath: "/Users/me/Movies/DemoTape/clip-brief",
                                           briefMarkdown: "IGNORED", mode: .agent)
        XCTAssertTrue(prompt.contains("/Users/me/Movies/DemoTape/clip-brief"))
        XCTAssertTrue(prompt.contains("BRIEF.md"))
        XCTAssertFalse(prompt.contains("IGNORED"), "agent prompt points at files rather than inlining them")
    }

    func testWebPromptInlinesTheBrief() {
        let prompt = AIBrief.handoffPrompt(sampleContent(), bundleDirPath: "/x/clip-brief",
                                           briefMarkdown: "INLINED BRIEF BODY", mode: .web)
        XCTAssertTrue(prompt.contains("INLINED BRIEF BODY"), "web prompt inlines the brief for a browser chat")
    }

    func testManifestJSONRoundTripsCoreFields() throws {
        let data = AIBrief.manifestJSON(sampleContent(), sourceName: "clip.mov", duration: 12)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["intent"] as? String, "bug")
        XCTAssertEqual(obj?["title"] as? String, "Save button does nothing")
        XCTAssertEqual(obj?["transcript"] as? String, "transcript.srt")
        XCTAssertEqual(obj?["events"] as? String, "events.json")
    }
}
