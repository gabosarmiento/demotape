import Foundation

/// The **AI** half of the director. It fuses the recording's transcript (what you're saying) with
/// its event stream (what you're doing) and asks an OpenAI-compatible chat model to place the
/// presenter cuts like a director: cut to the webcam when you're explaining/introducing, stay on
/// the screen when you're demonstrating. Bring-your-own-key; the same endpoint used for captions.
///
/// Only cut *placement* is delegated to the model — the actual motion (Ken Burns, left→right pan,
/// zoom reset) is applied by `AutoDirector.timeline`, so the look stays consistent and safe.
final class LLMDirector {

    struct Config {
        var baseURL: String
        var model: String
        var apiKey: String
    }

    enum LLMError: LocalizedError {
        case missingKey, network(String), api(String), decode(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "No API key for the AI director."
            case .network(let m): return "Network error: \(m)"
            case .api(let m): return "AI director API error: \(m)"
            case .decode(let m): return "Couldn't read the AI director response: \(m)"
            }
        }
    }

    // MARK: - Prompt building (pure/testable)

    /// A compact, timestamped view of the recording that mixes narration with activity markers,
    /// so the model can reason about explanation vs. hands-on demonstration.
    static func timelineText(metadata: RecordingMetadata, cues: [CaptionCue]) -> String {
        struct Line { let t: Double; let text: String }
        var lines = [Line]()
        for c in cues {
            let words = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { lines.append(Line(t: c.start, text: "SAY: \(words)")) }
        }
        // Bucket activity into 1s markers so the model sees when hands are busy.
        var busy = Set<Int>()
        for c in metadata.clicks { busy.insert(Int(c.t)) }
        for k in metadata.keys { busy.insert(Int(k.t)) }
        for s in metadata.scrolls { busy.insert(Int(s.t)) }
        for sec in busy.sorted() { lines.append(Line(t: Double(sec), text: "DO: on-screen activity (clicks/typing)")) }

        lines.sort { $0.t < $1.t }
        return lines.map { String(format: "[%.1f] %@", $0.t, $0.text) }.joined(separator: "\n")
    }

    private static func systemPrompt(duration: Double) -> String {
        """
        You are the director AND switcher of a \(Int(duration))-second software product demo. You \
        cut and frame it from two live feeds so it feels like a polished launch video.

        Your shot palette (framing):
        - "screen": the polished screen program (already has cursor + auto zoom-in on clicks). Use \
        it whenever the user is doing something on screen (there is "DO:" activity).
        - "presenter_full": the presenter on camera, medium framing. Use for intros/outros and \
        explanations with no on-screen activity.
        - "presenter_close": a tight, intimate close-up of the presenter. Use for a key statement, \
        a hook, or an emotional/important line.
        - "split": screen and presenter side by side (a two-shot). Use when the presenter is \
        talking about something that is also worth seeing on screen.

        Camera move per shot:
        - "still", "push_in" (slow emphasis), or "pan" (a gentle left→right drift).

        Direction rules:
        - Never cut during on-screen activity — stay on "screen" there.
        - Open on the presenter (a warm intro) and close on the presenter (a sign-off) when there \
        is narration to support it.
        - Vary framing so it never feels static; use close-ups sparingly for impact.
        - Each shot 2.5–7s; cut on the rhythm of the narration, not mid-sentence.

        Return ONLY JSON, no prose:
        {"shots":[{"start":<sec>,"end":<sec>,"framing":"screen|presenter_full|presenter_close|split","move":"still|push_in|pan"}]}
        Cover the whole timeline in order; it's fine for most of it to be "screen".
        """
    }

    // MARK: - Response parsing (pure/testable)

    /// Extracts `{shots:[…]}` from a model reply (tolerating prose/code-fences).
    static func parseShots(fromContent content: String) -> [DirectorShot] {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}") else { return [] }
        let json = String(content[start...end])
        guard let data = json.data(using: .utf8) else { return [] }
        struct Resp: Decodable {
            struct S: Decodable { let start: Double; let end: Double; let framing: String?; let move: String? }
            let shots: [S]
        }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        return decoded.shots.map {
            DirectorShot(start: $0.start, end: $0.end,
                         framing: framing(from: $0.framing), move: move(from: $0.move))
        }
    }

    private static func framing(from s: String?) -> ShotFraming {
        switch (s ?? "").lowercased() {
        case let x where x.contains("close"): return .presenterClose
        case let x where x.contains("presenter") || x.contains("full") || x.contains("cam"): return .presenterFull
        case let x where x.contains("split"): return .split
        default: return .screen
        }
    }
    private static func move(from s: String?) -> ShotMove {
        switch (s ?? "").lowercased() {
        case let x where x.contains("push"): return .pushIn
        case let x where x.contains("pan"): return .panRight
        default: return .still
        }
    }

    // MARK: - Network

    /// Requests a full shot list from the chat model. Runs synchronously; call off the main
    /// thread. Never called from tests (it makes a paid API call).
    func requestShots(config: Config, metadata: RecordingMetadata, cues: [CaptionCue]) throws -> [DirectorShot] {
        guard !config.apiKey.isEmpty else { throw LLMError.missingKey }
        var base = config.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.api("bad URL") }

        let text = Self.timelineText(metadata: metadata, cues: cues)
        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": Self.systemPrompt(duration: metadata.duration)],
                ["role": "user", "content": text]
            ]
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var respData: Data?, respErr: Error?, http: HTTPURLResponse?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, e in
            respData = d; respErr = e; http = r as? HTTPURLResponse; sema.signal()
        }.resume()
        sema.wait()

        if let respErr = respErr { throw LLMError.network(respErr.localizedDescription) }
        guard let http = http else { throw LLMError.network("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.api("HTTP \(http.statusCode): \((respData.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(300))")
        }
        guard let data = respData else { throw LLMError.decode("empty body") }

        struct ChatResp: Decodable {
            struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(ChatResp.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw LLMError.decode("no choices")
        }
        return Self.parseShots(fromContent: content)
    }
}
