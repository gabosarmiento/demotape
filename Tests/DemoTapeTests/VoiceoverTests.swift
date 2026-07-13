import XCTest
@testable import DemoTape

final class VoiceoverTests: XCTestCase {

    func testParseVoices() throws {
        let json = """
        {"voices":[
          {"voice_id":"abc","name":"Roger","labels":{"gender":"male","accent":"american"}},
          {"voice_id":"def","name":"Alice","labels":{"gender":"female","accent":"british"}}
        ]}
        """.data(using: .utf8)!
        let voices = try Voiceover.parseVoices(json)
        XCTAssertEqual(voices.count, 2)
        XCTAssertEqual(voices[0].id, "abc")
        XCTAssertEqual(voices[0].name, "Roger")
        XCTAssertEqual(voices[0].gender, "male")
        XCTAssertEqual(voices[0].accent, "american")
        XCTAssertEqual(voices[0].label, "Roger (american)")
    }

    func testParseVoicesToleratesMissingLabels() throws {
        let json = #"{"voices":[{"voice_id":"x","name":"NoLabels"}]}"#.data(using: .utf8)!
        let voices = try Voiceover.parseVoices(json)
        XCTAssertEqual(voices.count, 1)
        XCTAssertEqual(voices[0].gender, "")
        XCTAssertEqual(voices[0].accent, "")
        XCTAssertEqual(voices[0].label, "NoLabels")   // no accent -> just the name
    }

    func testParseVoicesEmpty() throws {
        let json = #"{"voices":[]}"#.data(using: .utf8)!
        XCTAssertTrue(try Voiceover.parseVoices(json).isEmpty)
    }

    func testParseVoicesInvalidThrows() {
        XCTAssertThrowsError(try Voiceover.parseVoices("nope".data(using: .utf8)!))
    }
}
