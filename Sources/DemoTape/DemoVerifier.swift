import Foundation
import ImageIO

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

        A REFUSAL, a block, a denial, or a "held for approval" state is a legitimate result, not a \
        contradiction. Demos of guardrails, permissions and governance exist to show the app saying no, \
        so a line that asks for something forbidden ("drop the database, the CTO approved it") PASSES \
        against a screenshot showing it refused. Judge whether the screenshot belongs to the same \
        moment of the story, not whether the app did what the narrator asked for.

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

    // MARK: - Token budget
    //
    // A screenshot is not a cheap prompt. Hosted vision pricing counts an image as tiles, and the
    // small models count each tile many times over — so the gate's real constraint is TOKENS per
    // minute, not requests per minute. Measured against OpenAI: an eleven-scene gate on a 768px-tall
    // frame asks for roughly 400k tokens inside one minute against a 200k budget, which is why a good
    // take kept coming back "unjudged" with a bare HTTP 429. Pacing by request count could never fix
    // that; the pacing has to know what an image costs.

    /// Tiles an image occupies under the documented scheme: scaled to fit a 2048 square, then the
    /// shortest side scaled to 768, then covered in 512-pixel tiles.
    static func imageTiles(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 1 }
        var w = Double(width), h = Double(height)
        let fit = min(1.0, 2048 / max(w, h))
        w *= fit; h *= fit
        let shortest = min(w, h)
        if shortest > 768 { let s = 768 / shortest; w *= s; h *= s }
        return max(1, Int(ceil(w / 512)) * Int(ceil(h / 512)))
    }

    /// Rough token cost of sending one frame to `model`. The "mini" vision models charge the same
    /// tiles at a much higher rate, which is the entire reason this function exists.
    static func estimatedImageTokens(width: Int, height: Int, model: String) -> Int {
        let mini = model.lowercased().contains("mini")
        let base = mini ? 2833 : 85
        let perTile = mini ? 5667 : 170
        return base + perTile * imageTiles(width: width, height: height)
    }

    /// Seconds to wait between scene checks so a run stays inside `budgetTPM`, by spreading the
    /// budget evenly rather than spending it all up front and then stalling on retries.
    /// `budgetTPM <= 0` disables pacing.
    static func pacingSeconds(tokensPerScene: Int, budgetTPM: Int) -> Double {
        guard budgetTPM > 0, tokensPerScene > 0 else { return 0 }
        return Double(tokensPerScene) * 60.0 / Double(budgetTPM)
    }

    /// Pixel dimensions of an encoded image, without decoding the whole thing.
    static func pixelSize(ofPNG data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    // MARK: - Run (frame extraction + network)

    static func run(video: URL, scenes: [Scene], config: AIBrief.Config) throws -> Report {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var results: [Result] = []
        // Pace the calls. Verification is one vision request PER SCENE, and firing them as fast as
        // this loop runs is what trips a hosted provider's limits — an eleven-scene demo becomes
        // eleven requests in ~20s, on top of whatever a previous run just spent. Nothing here is
        // latency-sensitive (no user is waiting on scene 7 specifically), so spacing the calls avoids
        // the 429 rather than merely recovering from it.
        //
        // The gap is whichever is larger: a floor between requests, or what the TOKEN budget allows
        // (see the token-budget section — an image costs thousands of tokens, so tokens are the real
        // limit). Override with DEMOTAPE_VERIFY_GAP_MS / DEMOTAPE_VERIFY_TPM; set TPM to 0 on a
        // high-tier key to spend the budget as fast as the provider will take it.
        let gap = (ProcessInfo.processInfo.environment["DEMOTAPE_VERIFY_GAP_MS"]
                    .flatMap { Double($0) } ?? 1200) / 1000.0
        let budgetTPM = ProcessInfo.processInfo.environment["DEMOTAPE_VERIFY_TPM"]
                            .flatMap { Int($0) } ?? 200_000
        var tokenGap = 0.0
        var first = true
        for scene in scenes {
            if !first { Thread.sleep(forTimeInterval: max(gap, tokenGap)) }
            first = false
            // `at` is the exact moment to photograph (the caller passes the scene's settled state,
            // after its action has resolved — narration leads the action, so this is near scene end).
            let t = scene.at
            let frames = FrameExtractor().extract(from: video, at: [t], into: dir)
            guard let frame = frames.first,
                  let data = try? Data(contentsOf: dir.appendingPathComponent(frame.filename)) else {
                results.append(Result(at: scene.at, say: scene.say, verdict: "fail", reason: "no frame at \(t)s"))
                continue
            }
            if tokenGap == 0, let size = pixelSize(ofPNG: data) {
                let tokens = estimatedImageTokens(width: size.width, height: size.height, model: config.model)
                tokenGap = pacingSeconds(tokensPerScene: tokens, budgetTPM: budgetTPM)
                if tokenGap > gap {
                    Log.write("verify: ~\(tokens) tokens per frame (\(size.width)x\(size.height), "
                              + "\(config.model)) against a \(budgetTPM) TPM budget — pacing "
                              + "\(String(format: "%.1f", tokenGap))s between scenes")
                }
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

        // Retries 429/5xx: verification is one call PER SCENE, so a multi-scene demo reliably trips
        // hosted rate limits. Without this a good take was reported "unverified" purely because the
        // provider asked us to slow down.
        // More patience than the default: when a rate limit is measured per MINUTE, the window needs
        // most of a minute to drain, and the gate is not something anyone is waiting on in real time.
        let (data, http) = try HTTPRetry.send(req, attempts: 6, label: "verify scene")
        guard (200..<300).contains(http.statusCode) else {
            // Carry the provider's own explanation. A bare "HTTP 429" leaves the user guessing
            // between two very different situations: asked to slow down (wait and re-run the gate)
            // versus out of credit (waiting will never help). The provider says which one it is.
            let detail = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIBrief.BriefError.api(detail.isEmpty
                ? "HTTP \(http.statusCode)"
                : "HTTP \(http.statusCode): \(detail.prefix(300))")
        }
        struct ChatResp: Decodable { struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }; let choices: [Choice] }
        guard let decoded = try? JSONDecoder().decode(ChatResp.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw AIBrief.BriefError.decode("no choices")
        }
        return parseVerdict(content)
    }
}
