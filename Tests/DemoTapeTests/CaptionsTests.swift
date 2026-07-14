import XCTest
@testable import DemoTape

final class CaptionsTests: XCTestCase {

    // MARK: - Endpoint building

    func testEndpointAppendsPath() {
        let url = Captions.transcriptionEndpoint(baseURL: "https://api.openai.com/v1")
        XCTAssertEqual(url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
    }

    func testEndpointToleratesTrailingSlash() {
        let url = Captions.transcriptionEndpoint(baseURL: "https://api.groq.com/openai/v1/")
        XCTAssertEqual(url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
    }

    func testEndpointTrimsWhitespaceAndMultipleSlashes() {
        let url = Captions.transcriptionEndpoint(baseURL: "  http://localhost:8080/v1//  ")
        XCTAssertEqual(url?.absoluteString, "http://localhost:8080/v1/audio/transcriptions")
    }

    func testEndpointEmptyReturnsNil() {
        XCTAssertNil(Captions.transcriptionEndpoint(baseURL: ""))
        XCTAssertNil(Captions.transcriptionEndpoint(baseURL: "   "))
    }

    // MARK: - Response parsing

    func testParseSegments() throws {
        let json = """
        {"text":"Hello world. Bye.","segments":[
          {"start":0.0,"end":1.5,"text":" Hello world."},
          {"start":1.5,"end":2.25,"text":"Bye. "}
        ]}
        """.data(using: .utf8)!
        let cues = try Captions.parseCues(fromVerboseJSON: json)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello world.")   // trimmed
        XCTAssertEqual(cues[0].start, 0.0)
        XCTAssertEqual(cues[0].end, 1.5)
        XCTAssertEqual(cues[1].text, "Bye.")
    }

    func testParseDropsEmptySegments() throws {
        let json = """
        {"text":"Hi","segments":[
          {"start":0.0,"end":1.0,"text":"Hi"},
          {"start":1.0,"end":2.0,"text":"   "}
        ]}
        """.data(using: .utf8)!
        let cues = try Captions.parseCues(fromVerboseJSON: json)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hi")
    }

    func testParseFallsBackToWholeText() throws {
        let json = #"{"text":"  Just one line.  "}"#.data(using: .utf8)!
        let cues = try Captions.parseCues(fromVerboseJSON: json)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Just one line.")
        XCTAssertEqual(cues[0].start, 0)
        XCTAssertEqual(cues[0].end, 0)
    }

    func testParseEmptyTextYieldsNoCues() throws {
        let json = #"{"text":"   "}"#.data(using: .utf8)!
        XCTAssertTrue(try Captions.parseCues(fromVerboseJSON: json).isEmpty)
    }

    func testParseInvalidJSONThrowsDecode() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try Captions.parseCues(fromVerboseJSON: json)) { error in
            guard case Captions.CaptionsError.decode = error else {
                return XCTFail("expected .decode, got \(error)")
            }
        }
    }

    // MARK: - SRT parsing (transcript reuse)

    func testParseSRTRoundTrips() {
        let cues = [
            CaptionCue(start: 0, end: 2.5, text: "Hello world"),
            CaptionCue(start: 2.5, end: 4.58, text: "Second line")
        ]
        let srt = Captions.srtString(cues)
        let parsed = Captions.parseSRT(srt)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].text, "Hello world")
        XCTAssertEqual(parsed[0].start, 0, accuracy: 1e-6)
        XCTAssertEqual(parsed[0].end, 2.5, accuracy: 1e-6)
        XCTAssertEqual(parsed[1].start, 2.5, accuracy: 1e-6)
        XCTAssertEqual(parsed[1].text, "Second line")
    }

    func testParseSRTMultiLineBodyJoined() {
        let srt = "1\n00:00:01,000 --> 00:00:03,000\nLine one\nline two\n\n"
        let parsed = Captions.parseSRT(srt)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].text, "Line one line two")
        XCTAssertEqual(parsed[0].start, 1.0, accuracy: 1e-6)
    }

    func testParseSRTHandlesHoursAndCRLF() {
        let srt = "1\r\n01:01:01,500 --> 01:01:02,000\r\nLate line\r\n\r\n"
        let parsed = Captions.parseSRT(srt)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].start, 3661.5, accuracy: 1e-6)
        XCTAssertEqual(parsed[0].text, "Late line")
    }

    // MARK: - SRT output

    func testSRTFormatting() {
        let cues = [
            CaptionCue(start: 0, end: 2.5, text: "Hello"),
            CaptionCue(start: 2.5, end: 4.58, text: "World")
        ]
        let expected = """
        1
        00:00:00,000 --> 00:00:02,500
        Hello

        2
        00:00:02,500 --> 00:00:04,580
        World


        """
        XCTAssertEqual(Captions.srtString(cues), expected)
    }

    func testSRTTimestampHoursAndMillisRounding() {
        // 1h 1m 1.5s should render with hours and rounded milliseconds.
        let cues = [CaptionCue(start: 3661.5, end: 3661.9999, text: "x")]
        let srt = Captions.srtString(cues)
        XCTAssertTrue(srt.contains("01:01:01,500 --> 01:01:02,000"), srt)
    }

    // MARK: - VTT output

    func testVTTHeaderAndDotSeparator() {
        let cues = [CaptionCue(start: 0, end: 1.25, text: "Hi")]
        let vtt = Captions.vttString(cues)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:01.250"), vtt)
    }

    func testNegativeTimeClampedToZero() {
        let cues = [CaptionCue(start: -5, end: 1, text: "Hi")]
        XCTAssertTrue(Captions.vttString(cues).contains("00:00:00.000 --> 00:00:01.000"))
    }

    // MARK: - Word-level timing (animated captions)

    func testParseDistributesWordsToSegmentsByMidpoint() throws {
        let json = """
        {"text":"Hello world bye now","segments":[
          {"start":0.0,"end":1.0,"text":"Hello world"},
          {"start":1.0,"end":2.0,"text":"bye now"}
        ],"words":[
          {"word":"Hello","start":0.0,"end":0.4},
          {"word":"world","start":0.4,"end":0.9},
          {"word":"bye","start":1.1,"end":1.4},
          {"word":"now","start":1.5,"end":1.9}
        ]}
        """.data(using: .utf8)!
        let cues = try Captions.parseCues(fromVerboseJSON: json)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].words?.map { $0.text }, ["Hello", "world"])
        XCTAssertEqual(cues[1].words?.map { $0.text }, ["bye", "now"])
        XCTAssertEqual(cues[0].words?.first?.start ?? -1, 0.0, accuracy: 1e-6)
    }

    func testParseWithoutWordsLeavesNilWords() throws {
        let json = """
        {"text":"Hello","segments":[{"start":0.0,"end":1.0,"text":"Hello"}]}
        """.data(using: .utf8)!
        let cues = try Captions.parseCues(fromVerboseJSON: json)
        XCTAssertNil(cues[0].words)
    }

    func testParseWholeTextCarriesWords() throws {
        let json = """
        {"text":"Hi there","words":[
          {"word":"Hi","start":0.0,"end":0.3},
          {"word":"there","start":0.3,"end":0.8}
        ]}
        """.data(using: .utf8)!
        let cues = try Captions.parseCues(fromVerboseJSON: json)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].words?.count, 2)
    }
}
