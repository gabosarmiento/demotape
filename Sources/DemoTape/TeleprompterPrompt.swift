import Foundation

/// The ready-made meta-prompt copied by the teleprompter's "Copy AI script prompt" button.
///
/// It's written so a user can paste it straight into any assistant and get back a script that fits
/// DemoTape's teleprompter: first-person, spoken (not written) English, conversational, and short
/// enough to read aloud in under a minute. The `[describe what you're demoing]` placeholder is left
/// for the user to fill in — that's the one thing the assistant can't know.
enum TeleprompterPrompt {

    static let placeholder = "[describe what you're demoing]"

    static let text = """
    Write me a short spoken narration script for a product demo video.

    What I'm demoing: \(placeholder)

    Requirements:
    - First person, as if I'm talking to a viewer while I click through the product \
    ("okay, let me show you…", "now I'll…"). Not marketing copy, no slogans.
    - Conversational and plain — the way I'd actually explain it to a colleague out loud.
    - Sayable in English in UNDER ONE MINUTE at a natural pace (roughly 130–150 words).
    - One idea per sentence, short sentences, so it's easy to read off a teleprompter.
    - Use commas and "…" for natural pauses. No headings, no bullet points, no stage \
    directions — just the words I will speak, as a single flowing paragraph.
    - Don't invent features or numbers; only describe what I actually show.

    Return only the script text, nothing else.
    """
}
