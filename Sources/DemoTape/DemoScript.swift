import Foundation

/// Builds the **handoff prompt** for the "Create Demo with AI" composer. You type *what* you want
/// demoed (and point at a project); DemoTape wraps it into a precise brief you paste into a coding
/// agent (Kiro / Claude Code) that has access to that codebase. The agent then: reads the code to
/// understand the feature, writes a tight 30s–2min narration script, records the walkthrough via
/// DemoTape's `demotape://` control surface, and lays an ElevenLabs voiceover over it.
///
/// Pure/testable string assembly — no I/O.
enum DemoScript {

    /// Approximate spoken words for a target duration (~150 wpm, a natural narration pace).
    static func approxWordBudget(seconds: Int) -> Int { max(30, Int(Double(seconds) / 60.0 * 150)) }

    /// The prompt the user copies into their coding agent.
    static func kiroPrompt(idea: String, projectPath: String, targetSeconds: Int, voiceId: String?) -> String {
        let trimmedIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        let ideaLine = trimmedIdea.isEmpty ? "a short product demo of this project" : trimmedIdea
        let words = approxWordBudget(seconds: targetSeconds)
        let mmss = String(format: "%d:%02d", targetSeconds / 60, targetSeconds % 60)
        let voiceClause = (voiceId?.isEmpty == false)
            ? " Use ElevenLabs voice id `\(voiceId!)`."
            : " Pick a fitting ElevenLabs voice (list them with `DemoTape --voices`)."

        return """
        You are producing a short, real screen-recorded product demo with DemoTape, driven by the \
        Playwright driver in `tools/demo-driver/`. You have access to the project below — read it \
        first so the demo is accurate.

        PROJECT: \(projectPath.isEmpty ? "(the current workspace)" : projectPath)
        DEMO: \(ideaLine)
        TARGET LENGTH: about \(mmss) (~\(words) words of narration).

        Do this in order:

        1. UNDERSTAND — Explore the project (README, routes/pages, key components) enough to describe \
        the feature truthfully. Do not invent capabilities that aren't in the code. Note the local \
        URL to demo (e.g. http://localhost:3000/…) and the selectors you'll click.

        2. WRITE A SCENES CONFIG — Author a JSON config for the driver (see \
        `tools/demo-driver/demo.example.json`). It's an array of `scenes`, and each scene pairs:
           - `say`: what you speak while that scene plays — first-person and conversational, like a \
        real person showing a colleague their screen ("okay, let me show you…", "now I'll click \
        here…", "see how…"). NOT a marketing voiceover. Use commas and the occasional "…" for \
        natural pauses.
           - `steps`: the Playwright actions performed WHILE that line is spoken — \
        goto / click / fill / press / scroll / hover / waitFor / wait, with CSS/text selectors.
           - `expect` (for any scene with a real action): the post-condition that PROVES it worked, \
        e.g. {"urlContains":"/docs","visible":"text=Installation"}. This is asserted at record time \
        like a test — so a failed click can't silently produce a lying video.
           The driver leads each line then fires its action, so put the line and the action it \
        describes in the SAME scene. Keep total narration within ~\(words) words; open with a casual \
        hook and close with a plain takeaway. Set `url`, `viewport`, and the voice.\(voiceClause)

        3. RUN — Make sure DemoTape is running (it's the recorder), then:
             node tools/demo-driver/driver.mjs your-demo.json
           The driver records, keeps each line synced to its scene, asserts every `expect`, renders, \
           lays the voiceover, then VERIFIES the render (a vision model checks each frame matches its \
           line) and RETRIES on any failure — it only presents a demo that matches the script, and \
           writes a `demo-report.json` beside the video.

        4. HAND BACK — Tell me the final video path, the verification report result, and anything \
           you'd tighten on a second pass.

        Keep it honest and crisp — this is a real demo we'll show, not a movie. If the project can't \
        run locally or a step is ambiguous, ask me before recording.
        """
    }
}
