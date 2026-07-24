import Foundation

/// Turns a short "explain it to the AI" screen recording into a structured, LLM-optimized brief.
///
/// The flow fuses three things DemoTape already captures — your **narration** (transcribed by
/// `Captions`), what you **did** (`RecordingMetadata` clicks/keys/scrolls), and a handful of
/// **keyframes** — and asks an OpenAI-compatible multimodal chat model to *understand* it and
/// author the brief (problem statement, intent, observed vs. expected, repro steps, open
/// questions, per-frame notes).
///
/// Bring-your-own-key (the same key/endpoint captions use). The result is a self-contained
/// `<name>-brief/` folder plus a copy-paste handoff prompt: the primary path points a coding
/// agent (Kiro / Claude Code) at the local folder; a `.zip` with the content inlined is the
/// fallback for web chat that can't read local files.
///
/// This file holds the **pure, network-free logic** (prompt building, response parsing, keyframe
/// selection, and the markdown/prompt/json builders) so it's unit-testable. Frame extraction,
/// transcription, the API call, and bundle assembly live in `AIBriefBuilder`.
enum AIBrief {

    // MARK: - Model

    /// What the recording is fundamentally about — lets a consuming agent act appropriately.
    enum Intent: String, Codable, Equatable {
        case bug, behavior, change, question, other

        /// Human label for the brief header.
        var label: String {
            switch self {
            case .bug: return "Bug / something broken"
            case .behavior: return "Current behavior to change"
            case .change: return "Requested change / new feature"
            case .question: return "Question"
            case .other: return "Note"
            }
        }

        /// A verb phrase for the handoff prompt ("… explaining <phrase>").
        var promptPhrase: String {
            switch self {
            case .bug: return "a bug I'm hitting"
            case .behavior: return "a behavior I want to change"
            case .change: return "a change I'd like made"
            case .question: return "a question about the code"
            case .other: return "something in the app"
            }
        }

        /// A default "what I'd like you to do" line, when the recording is this kind.
        var defaultAsk: String {
            switch self {
            case .bug: return "Find the root cause and propose (or make) a fix."
            case .behavior: return "Change the behavior to match what I describe."
            case .change: return "Implement the change I describe."
            case .question: return "Answer the question, reading the code as needed."
            case .other: return "Take a look and tell me how you'd approach it."
            }
        }

        /// Tolerant mapping from a model-produced string.
        static func from(_ raw: String?) -> Intent {
            let x = (raw ?? "").lowercased()
            if x.contains("bug") || x.contains("broken") || x.contains("error") || x.contains("crash") { return .bug }
            if x.contains("behav") { return .behavior }
            if x.contains("change") || x.contains("feature") || x.contains("request") || x.contains("want") || x.contains("add") { return .change }
            if x.contains("question") || x.contains("ask") || x.contains("how") { return .question }
            return .other
        }
    }

    /// One keyframe reference inside the bundle (`frames/<filename>`), with an AI note.
    struct Frame: Codable, Equatable {
        var t: Double          // seconds into the recording
        var filename: String   // e.g. "0007s.png"
        var note: String?      // model's description of what this frame shows
    }

    /// The AI-authored brief. Encoded verbatim as `brief.json` and rendered into `BRIEF.md`.
    struct Content: Codable, Equatable {
        var title: String
        var intent: Intent
        var summary: String
        var observed: String
        var expected: String
        var steps: [String]
        var questions: [String]
        var frames: [Frame]
    }

    // MARK: - Config

    /// OpenAI-compatible chat config (same endpoint/key as captions & the AI director).
    struct Config {
        var baseURL: String
        var model: String
        var apiKey: String
    }

    enum BriefError: LocalizedError {
        case missingKey, network(String), api(String), decode(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "No API key for the AI brief."
            case .network(let m): return "Network error: \(m)"
            case .api(let m): return "AI brief API error: \(m)"
            case .decode(let m): return "Couldn't read the AI brief response: \(m)"
            }
        }
    }

    // MARK: - Keyframe selection (pure/testable)

    /// Chooses the timestamps worth screenshotting for a *short* brief (30s–3min). Candidates are
    /// the moments the model most needs to see: just after each click (the result of an action),
    /// the start of each spoken cue (a new thing being explained), plus the opening and a near-end
    /// frame. Candidates are then thinned to respect `minGap` and capped at `maxFrames` so we never
    /// send a wall of near-identical screenshots. (Visual de-duplication happens later, once the
    /// pixels exist, in `AIBriefBuilder`.)
    static func keyframeTimestamps(metadata: RecordingMetadata,
                                   cues: [CaptionCue],
                                   maxFrames: Int = 8,
                                   minGap: Double = 1.5) -> [Double] {
        let duration = max(0, metadata.duration)
        var candidates: [Double] = [0.0]
        for c in metadata.clicks { candidates.append(min(duration, c.t + 0.4)) }
        for cue in cues where cue.start > 0 { candidates.append(cue.start) }
        if duration > 2 { candidates.append(max(0, duration - 0.8)) }

        // Sort, clamp, and greedily keep frames spaced at least `minGap` apart.
        let sorted = candidates.map { min(max(0, $0), duration) }.sorted()
        var kept: [Double] = []
        for t in sorted {
            if let last = kept.last, t - last < minGap { continue }
            kept.append(t)
        }
        // If greedy thinning left us with too many, sample evenly across what remains.
        guard kept.count > maxFrames else { return kept }
        var thinned: [Double] = []
        let stride = Double(kept.count - 1) / Double(maxFrames - 1)
        for i in 0..<maxFrames { thinned.append(kept[Int((Double(i) * stride).rounded())]) }
        return Array(Set(thinned)).sorted()
    }

    /// Stable, sortable frame filename for a timestamp, e.g. 7.2s → "0007s.png".
    static func frameFilename(forTimestamp t: Double) -> String {
        String(format: "%04ds.png", Int(t.rounded()))
    }

    // MARK: - Prompt building (pure/testable)

    /// A compact, timestamped transcript of the recording that interleaves what was **said** with
    /// markers for on-screen **activity**, so the model can correlate narration with actions.
    static func timelineText(metadata: RecordingMetadata, cues: [CaptionCue]) -> String {
        struct Line { let t: Double; let text: String }
        var lines: [Line] = []
        for c in cues {
            let words = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { lines.append(Line(t: c.start, text: "SAY: \(words)")) }
        }
        // Describe activity per 1s bucket, noting clicks/typing/scrolls distinctly.
        var clickSecs = Set<Int>(), keySecs = Set<Int>(), scrollSecs = Set<Int>()
        for c in metadata.clicks { clickSecs.insert(Int(c.t)) }
        for k in metadata.keys { keySecs.insert(Int(k.t)) }
        for s in metadata.scrolls { scrollSecs.insert(Int(s.t)) }
        for sec in clickSecs.union(keySecs).union(scrollSecs).sorted() {
            var what: [String] = []
            if clickSecs.contains(sec) { what.append("click") }
            if keySecs.contains(sec) { what.append("typing") }
            if scrollSecs.contains(sec) { what.append("scroll") }
            lines.append(Line(t: Double(sec), text: "DO: \(what.joined(separator: "+"))"))
        }
        lines.sort { $0.t < $1.t }
        return lines.map { String(format: "[%.1f] %@", $0.t, $0.text) }.joined(separator: "\n")
    }

    /// System prompt for the **text-only** intent analysis. Deliberately sees no screenshots, so
    /// the brief can only be driven by what the developer actually said and did — never by text
    /// that happens to be visible on screen (a menu, another app, a previous result still shown).
    static func briefSystemPrompt(duration: Double) -> String {
        """
        You analyze a SHORT (\(Int(duration))s) screen recording in which a developer explains \
        something to a coding agent — a bug, a behavior they want changed, a feature request, or a \
        question. You are given a timestamped transcript of what they SAID interleaved with markers \
        of what they DID on screen (clicks/typing/scrolls). This is the ONLY input; there are no \
        screenshots. Determine what the recording is about strictly from this narration and activity.

        Produce a tight, high-signal brief optimized for another AI to act on. Derive reproduction \
        steps from the DO markers and narration. Be concise and concrete; do not invent details. If \
        the narration is too vague to determine intent, say so in the summary and put the gaps under \
        "questions" rather than guessing.

        Return ONLY JSON, no prose, in exactly this shape:
        {
          "title": "<one short line naming the issue/request>",
          "intent": "bug|behavior|change|question|other",
          "summary": "<2-4 sentences: what this is about>",
          "observed": "<what currently happens; empty string if N/A>",
          "expected": "<what they want to happen; empty string if N/A>",
          "steps": ["<step>", "..."],
          "questions": ["<open question or assumption to confirm>", "..."]
        }
        """
    }

    /// System prompt for the **frame-captioning** pass. The screenshots are used ONLY to describe
    /// what's visible; they must never redefine the topic (a frame may show stale/unrelated UI).
    static func frameNotesSystemPrompt(frameCount: Int, context: String) -> String {
        """
        You are captioning \(frameCount) screenshots taken (in order) from a screen recording. \
        For reference, the recording is about: "\(context)".

        For each screenshot, write ONE short, factual sentence describing only what is visibly on \
        screen. Do NOT infer or restate the recording's purpose, and do NOT treat text shown on \
        screen (menus, other apps, a previous result left open) as the topic — just describe what \
        you see.

        Return ONLY JSON, no prose: {"frameNotes":["<screenshot 1>","<screenshot 2>", "..."]} \
        with exactly \(frameCount) entries, in order.
        """
    }

    // MARK: - Response parsing (pure/testable)

    /// Parses the model's JSON reply (tolerating prose/code fences) and attaches the frame notes to
    /// the caller's already-extracted `frames` (matched by order). Returns nil if no JSON is found.
    static func parseBrief(fromContent content: String, frames: [Frame]) -> Content? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              let data = String(content[start...end]).data(using: .utf8) else { return nil }

        struct Raw: Decodable {
            let title: String?
            let intent: String?
            let summary: String?
            let observed: String?
            let expected: String?
            let steps: [String]?
            let questions: [String]?
            let frameNotes: [String]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }

        var annotated = frames
        if let notes = raw.frameNotes {
            for i in 0..<annotated.count where i < notes.count {
                let n = notes[i].trimmingCharacters(in: .whitespacesAndNewlines)
                annotated[i].note = n.isEmpty ? nil : n
            }
        }

        let title = (raw.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Screen recording brief"
        return Content(
            title: title,
            intent: Intent.from(raw.intent),
            summary: raw.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            observed: raw.observed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            expected: raw.expected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            steps: (raw.steps ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            questions: (raw.questions ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            frames: annotated)
    }

    /// Parses `{"frameNotes":[...]}` from the captioning pass (tolerating prose/fences).
    static func parseFrameNotes(fromContent content: String) -> [String] {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              let data = String(content[start...end]).data(using: .utf8) else { return [] }
        struct Raw: Decodable { let frameNotes: [String]? }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return [] }
        return (raw.frameNotes ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Attaches captions to frames by order (used after the frame-notes pass).
    static func attachNotes(_ notes: [String], to frames: [Frame]) -> [Frame] {
        var out = frames
        for i in 0..<out.count where i < notes.count {
            let n = notes[i].trimmingCharacters(in: .whitespacesAndNewlines)
            out[i].note = n.isEmpty ? nil : n
        }
        return out
    }

    // MARK: - Output builders (pure/testable)

    /// The agent-first `BRIEF.md`. Sections with no content are omitted.
    static func briefMarkdown(_ c: Content, sourceName: String, duration: Double) -> String {
        var out = "# \(c.title)\n\n"
        out += "**Type:** \(c.intent.label)  \n"
        out += "**Recording:** \(sourceName) · \(timecode(duration))\n\n"

        if !c.summary.isEmpty { out += "## Summary\n\(c.summary)\n\n" }
        if !c.observed.isEmpty { out += "## Observed\n\(c.observed)\n\n" }
        if !c.expected.isEmpty { out += "## Expected\n\(c.expected)\n\n" }
        if !c.steps.isEmpty {
            out += "## Steps\n"
            for (i, s) in c.steps.enumerated() { out += "\(i + 1). \(s)\n" }
            out += "\n"
        }
        if !c.frames.isEmpty {
            out += "## Screenshots\n"
            for f in c.frames {
                let note = (f.note?.isEmpty == false) ? " — \(f.note!)" : ""
                out += "- `frames/\(f.filename)` (\(timecode(f.t)))\(note)\n"
            }
            out += "\n"
        }
        if !c.questions.isEmpty {
            out += "## Open questions\n"
            for q in c.questions { out += "- \(q)\n" }
            out += "\n"
        }
        out += "## Evidence\n"
        out += "- `transcript.srt` — full narration, timestamped\n"
        out += "- `events.json` — exact clicks / keystrokes / scroll timeline\n"
        return out
    }

    /// A machine-readable manifest (`brief.json`) tying the brief to its files.
    static func manifestJSON(_ c: Content, sourceName: String, duration: Double) -> Data {
        struct Manifest: Encodable {
            let sourceName: String
            let durationSeconds: Double
            let title: String
            let intent: String
            let summary: String
            let observed: String
            let expected: String
            let steps: [String]
            let questions: [String]
            let frames: [Frame]
            let transcript: String
            let events: String
        }
        let m = Manifest(sourceName: sourceName, durationSeconds: duration, title: c.title,
                         intent: c.intent.rawValue, summary: c.summary, observed: c.observed,
                         expected: c.expected, steps: c.steps, questions: c.questions, frames: c.frames,
                         transcript: "transcript.srt", events: "events.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(m)) ?? Data()
    }

    /// Delivery target for the copy-paste prompt.
    enum PromptMode { case agent, web }

    /// The copy-paste handoff.
    ///
    /// - `.agent` (Kiro / Claude Code): references the bundle's absolute path so the agent reads the
    ///   files itself — the primary, "optimized for LLM consumption" path.
    /// - `.web` (ChatGPT/Claude in a browser): inlines BRIEF.md since the model can't read local
    ///   files, and asks the user to attach the screenshots from the zip.
    static func handoffPrompt(_ c: Content, bundleDirPath: String, briefMarkdown: String, mode: PromptMode) -> String {
        let ask = c.intent.defaultAsk
        switch mode {
        case .agent:
            return """
            I recorded a short screen walkthrough explaining \(c.intent.promptPhrase). I've prepared \
            an AI brief for you here:

            \(bundleDirPath)

            Start by reading BRIEF.md — my analyzed summary. Supporting evidence is in the same folder:
            - frames/ — key screenshots, each noted in BRIEF.md
            - transcript.srt — my narration, timestamped
            - events.json — the exact clicks/keystrokes timeline

            Summary: \(c.title) — \(c.summary)

            What I'd like you to do: \(ask) Ask me if anything is ambiguous before making large changes.
            """
        case .web:
            return """
            I recorded a short screen walkthrough explaining \(c.intent.promptPhrase). Here is my \
            analyzed brief. I'll attach the key screenshots referenced below.

            ---
            \(briefMarkdown)
            ---

            What I'd like you to do: \(ask) Ask me if anything is ambiguous.
            """
        }
    }

    // MARK: - Helpers

    static func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
