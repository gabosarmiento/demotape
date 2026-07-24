import Foundation

/// Self-verification for AI-led demos: does the rendered video actually show what the script says?
///
/// For each scene it grabs the frame at that scene's moment and asks a multimodal model whether the
/// screenshot supports the narration line. It returns a per-scene PASS/FAIL report so the pipeline
/// can gate the output (and self-correct) with no human in the loop — the same idea as running a
/// test suite before shipping code. Bring-your-own-key; reuses the captions/brief endpoint.
///
/// The pure parsing/prompt logic here is unit-tested; the frame extraction + network call live in
/// `run(...)`.
enum DemoVerifier {

    struct Scene: Codable { let at: Double; let say: String }
    struct Result: Codable { let at: Double; let say: String; let verdict: String; let reason: String }
    struct Report: Codable { let pass: Bool; let scenes: [Result] }

    /// Strict, lenient-on-wording verification prompt.
    static func systemPrompt() -> String {
        """
        You verify a screenshot from a hands-off product-demo recording against its narration line.

        The narration is a first-person walkthrough that usually says what the user is ABOUT TO DO; the \
        screenshot is captured just after, so it normally shows the RESULT of that action. Treat the \
        result as consistent. For example these all PASS: "I'll sign in" with the signed-in dashboard; \
        "let me open Build" with the Build page; "I'll activate it" with the resulting domains page; \
        "pretty clean, right?" with any plausible app screen.

        PASS whenever the screenshot is plausibly part of this app and consistent with the scene — \
        either the action or its result. FAIL ONLY on a clear problem: an error page, a blank / loading \
        / broken screen, the wrong application entirely, or a state that plainly contradicts the scene.

        Return ONLY JSON: {"verdict":"pass"|"fail","reason":"<short reason>"}.
        """
    }

    /// Parses the model reply (tolerating fences/prose). Unknown/garbled → treated as a fail so the
    /// pipeline never ships something it couldn't verify.
    static func parseVerdict(_ content: String) -> (verdict: String, reason: String) {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              let data = String(content[start...end]).data(using: .utf8) else {
            return ("fail", "no verdict returned")
        }
        struct Raw: Decodable { let verdict: String?; let reason: String? }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return ("fail", "unparseable verdict")
        }
        let v = (raw.verdict ?? "").lowercased().contains("pass") ? "pass" : "fail"
        return (v, raw.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Overall pass = every scene passed.
    static func overallPass(_ results: [Result]) -> Bool { !results.isEmpty && results.allSatisfy { $0.verdict == "pass" } }

    // MARK: - Run (frame extraction + network)

    static func run(video: URL, scenes: [Scene], config: AIBrief.Config) throws -> Report {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var results: [Result] = []
        for scene in scenes {
            // `at` is the exact moment to photograph (the caller passes the scene's settled state,
            // after its action has resolved — narration leads the action, so this is near scene end).
            let t = scene.at
            let frames = FrameExtractor().extract(from: video, at: [t], into: dir)
            guard let frame = frames.first,
                  let data = try? Data(contentsOf: dir.appendingPathComponent(frame.filename)) else {
                results.append(Result(at: scene.at, say: scene.say, verdict: "fail", reason: "no frame at \(t)s"))
                continue
            }
            let (verdict, reason) = try verifyScene(say: scene.say, imagePNG: data, config: config)
            results.append(Result(at: scene.at, say: scene.say, verdict: verdict, reason: reason))
        }
        return Report(pass: overallPass(results), scenes: results)
    }

    private static func verifyScene(say: String, imagePNG: Data, config: AIBrief.Config) throws -> (String, String) {
        var base = config.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw AIBrief.BriefError.api("bad URL") }

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.0,
            "messages": [
                ["role": "system", "content": systemPrompt()],
                ["role": "user", "content": [
                    ["type": "text", "text": "Narration line: \"\(say)\""],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(imagePNG.base64EncodedString())"]]
                ]]
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
        URLSession.shared.dataTask(with: req) { d, r, e in respData = d; respErr = e; http = r as? HTTPURLResponse; sema.signal() }.resume()
        sema.wait()
        if let respErr = respErr { throw AIBrief.BriefError.network(respErr.localizedDescription) }
        guard let http = http, (200..<300).contains(http.statusCode), let data = respData else {
            throw AIBrief.BriefError.api("HTTP \(http?.statusCode ?? -1)")
        }
        struct ChatResp: Decodable { struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }; let choices: [Choice] }
        guard let decoded = try? JSONDecoder().decode(ChatResp.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw AIBrief.BriefError.decode("no choices")
        }
        return parseVerdict(content)
    }
}
