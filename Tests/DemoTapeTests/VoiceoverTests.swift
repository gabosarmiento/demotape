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

    // MARK: - Quota / credits

    func testQuotaErrorDetectedFromRealBody() {
        let body = #"{"detail":{"type":"invalid_request","code":"quota_exceeded","message":"This request exceeds your quota of 10000. You have 49 credits remaining, while 112 credits are required for this request.","status":"quota_exceeded"}}"#
        guard let err = Voiceover.quotaError(status: 401, body: body) else {
            return XCTFail("expected a quota error")
        }
        guard case .quotaExceeded(let note) = err else { return XCTFail("wrong case") }
        XCTAssertEqual(note, "You have 49 credits remaining, while 112 credits are required for this request.")
        // The user-facing message must name the fix.
        XCTAssertTrue(err.errorDescription?.contains("out of credits") == true)
        XCTAssertTrue(err.errorDescription?.contains("elevenlabs.io") == true)
    }

    func testQuotaErrorNilForUnrelatedBody() {
        XCTAssertNil(Voiceover.quotaError(status: 500, body: #"{"detail":"server exploded"}"#))
        XCTAssertNil(Voiceover.quotaError(status: 401, body: #"{"detail":"invalid api key"}"#))
    }

    func testParseCreditsComputesRemaining() throws {
        let json = #"{"character_count":9551,"character_limit":10000}"#.data(using: .utf8)!
        let c = try Voiceover.parseCredits(json)
        XCTAssertEqual(c.used, 9551)
        XCTAssertEqual(c.limit, 10000)
        XCTAssertEqual(c.remaining, 449)
    }

    func testParseCreditsClampsNegativeRemaining() throws {
        let json = #"{"character_count":10050,"character_limit":10000}"#.data(using: .utf8)!
        XCTAssertEqual(try Voiceover.parseCredits(json).remaining, 0)
    }

    // MARK: - Pluggable TTS providers

    private func body(_ req: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testElevenLabsRequestShape() throws {
        let cfg = Voiceover.TTSConfig(provider: .elevenLabs, model: "eleven_multilingual_v2",
                                      voice: "VOICE123", apiKey: "sk_key")
        let req = try Voiceover.buildSynthesisRequest(text: "hi there", config: cfg)
        XCTAssertEqual(req.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/VOICE123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), "sk_key")
        let b = body(req)
        XCTAssertEqual(b["text"] as? String, "hi there")
        XCTAssertEqual(b["model_id"] as? String, "eleven_multilingual_v2")
        XCTAssertNotNil(b["voice_settings"])
    }

    func testElevenLabsRequiresKey() {
        let cfg = Voiceover.TTSConfig(provider: .elevenLabs, voice: "V", apiKey: "")
        XCTAssertThrowsError(try Voiceover.buildSynthesisRequest(text: "x", config: cfg))
    }

    func testOpenAICompatibleRequestShape() throws {
        let cfg = Voiceover.TTSConfig(provider: .openAICompatible, baseURL: "http://localhost:8880/v1/",
                                      model: "tts-1", voice: "af_bella", apiKey: "")
        let req = try Voiceover.buildSynthesisRequest(text: "hello world", config: cfg)
        // Trailing slash trimmed; /audio/speech appended.
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:8880/v1/audio/speech")
        // Keyless local server → no Authorization header.
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let b = body(req)
        XCTAssertEqual(b["model"] as? String, "tts-1")
        XCTAssertEqual(b["input"] as? String, "hello world")
        XCTAssertEqual(b["voice"] as? String, "af_bella")
        XCTAssertEqual(b["response_format"] as? String, "mp3")
    }

    func testOpenAICompatibleAddsBearerWhenKeyed() throws {
        let cfg = Voiceover.TTSConfig(provider: .openAICompatible, baseURL: "https://api.openai.com/v1",
                                      model: "tts-1", voice: "alloy", apiKey: "sk-abc")
        let req = try Voiceover.buildSynthesisRequest(text: "x", config: cfg)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-abc")
    }

    func testCustomRequestShape() throws {
        let cfg = Voiceover.TTSConfig(provider: .custom, baseURL: "http://localhost:8000/speak",
                                      model: "chatterbox", voice: "narrator", apiKey: "")
        let req = try Voiceover.buildSynthesisRequest(text: "read this", config: cfg)
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:8000/speak")   // posted as-is
        let b = body(req)
        XCTAssertEqual(b["text"] as? String, "read this")
        XCTAssertEqual(b["voice"] as? String, "narrator")
        XCTAssertEqual(b["model"] as? String, "chatterbox")
    }

    func testEnvConfigDefaultsToElevenLabs() {
        let c = Voiceover.TTSConfig.fromEnvironment(voice: "V", env: ["DEMOTAPE_ELEVEN_KEY": "sk_k"])
        XCTAssertEqual(c.provider, .elevenLabs)
        XCTAssertEqual(c.apiKey, "sk_k")
        XCTAssertEqual(c.voice, "V")
    }

    func testEnvConfigSelectsLocalProvider() {
        let env = ["DEMOTAPE_TTS_PROVIDER": "OpenAI-compatible",
                   "DEMOTAPE_TTS_BASEURL": "http://localhost:1234/v1",
                   "DEMOTAPE_TTS_MODEL": "kokoro"]
        let c = Voiceover.TTSConfig.fromEnvironment(voice: "", env: env)
        XCTAssertEqual(c.provider, .openAICompatible)
        XCTAssertEqual(c.baseURL, "http://localhost:1234/v1")
        XCTAssertEqual(c.model, "kokoro")
        XCTAssertEqual(c.voice, "alloy")   // filled default when none supplied
    }
}
