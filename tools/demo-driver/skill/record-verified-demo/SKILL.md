---
name: record-verified-demo
description: >
  Produce a real, narrated screen-recorded product demo of a running app, end-to-end and hands-off,
  using DemoTape + the Playwright demo-driver. Use this whenever the user wants to "record a demo",
  "make a walkthrough video", "show how <feature> works on video", "create a product demo",
  "demo the dashboard/app", or turn an idea into a narrated screencast — especially when the app is
  a local/web app the agent can drive. It covers understanding the app, standing up its local
  stack, discovering the real interaction flow and valid inputs from the code (never fixtures),
  scripting scenes, rehearsing headlessly, recording with a synced ElevenLabs voiceover, and
  self-verifying that the output matches the script before presenting it. Prefer this skill over
  ad-hoc screen recording whenever a demo video is the deliverable.
---

# Record a verified product demo

The goal is a short, honest, narrated demo of a **real** app running locally, produced without a
human in the loop and **proven to match its script** before it's shown — like running a test suite
before shipping. You are the director: you understand the app, write the script, drive the browser,
record with DemoTape, and verify the result.

The cardinal rule: **be real, not plausible.** Every claim in the narration must correspond to
something the app actually does, and every input you type must be valid according to the app's own
code — never a guessed or copied-from-tests value. When something fails, read the actual error and
the actual schema; do not paper over it.

## The pipeline

1. **Understand the app** — enough to demo it truthfully.
2. **Stand up the local stack** — get it running and reachable.
3. **Discover the real flow + valid inputs** — from routes, the UI, and the schema/validators.
4. **Author scenes** — line + action + expected outcome, paired so narration leads the action.
5. **Rehearse headlessly** — validate every step/assertion with no recording.
6. **Record + voice** — DemoTape records; each line is laid at its scene's moment (synced).
7. **Verify** — assertions (deterministic) + a vision check (semantic); retry or fail loudly.
8. **Hand back** — the video path, the verification report, and what you'd tighten.

Do not skip 5 (rehearsal). Recording a broken take wastes minutes and produces slop; a headless
rehearsal fails in seconds and tells you exactly which selector or input is wrong.

## 1. Understand the app

Read the README/AGENTS and, if present, a code graph (e.g. `graphify-out/` — see
`references/grounding-a-codebase.md`). Identify: what the feature does, the local URL to demo, and
the concrete UI path (which routes, which buttons/fields). Write nothing you can't point at in code.

## 2. Stand up the local stack

Find the run instructions (Makefile targets, `docker-compose.yml`, `.env.example`, README "local
dev"). Prefer the lightest path: many apps have an **in-memory / stub mode** (no DB, stubbed auth)
for local dev — look for env like `*_AUTH_PROVIDER=stub`, "falls back to in-memory", `*_DATABASE_URL`
optional. Start backend and frontend as background processes, then confirm health (`/healthz`) and
that the page you'll demo actually loads. Note any auth: stub/dev sign-in is usually a simple form.

Servers are long-running — start them as background processes and poll their health/logs; never
block on them.

## 3. Discover the real flow + valid inputs (do NOT monkeypatch)

This is where demos go wrong. Drive the *actual* UI to learn the real selectors and the real
create/interaction flow, and get valid input values from the **schema and validators**, not from
test fixtures (fixtures drift from the live validator).

- Inspect the rendered pages (curl with the session cookie, or read the templates/handlers) to find
  real form field names, button labels, and where actions post.
- UIs often use **progressive disclosure**: the field you need may be inside a collapsed
  `<details>`/accordion/tab. Expand it (see the driver's `expand` action) before filling.
- When an action is rejected, **read the validator's exact error** and fix the input against the
  schema. Example from a real run: a domain YAML failed with "unknown event ISSUE_REFUND" because a
  transition's `on:` must reference a declared `event`; and roles had to nest under `permissions:`
  per the parser struct — both discovered from the code + the error, not guessed.

Prove the whole flow works once (e.g. via curl or a headless script) and observe the real
end-state/success signal (a redirect target, a visible element) before you script assertions.

## 4. Author scenes

The demo is a list of **scenes**; each pairs what you SAY with what you DO and what you EXPECT.
See `references/demotape-driver.md` for the full config schema. Key ideas:

- **Narration is a first-person walkthrough**, conversational, saying what you're about to do as you
  do it ("okay, let me show you… now I'll click here…"). Not marketing copy. Commas and "…" become
  natural pauses. The driver **leads** the action with the line, so put the line and the action it
  describes in the *same* scene.
- **`expect`** is the post-condition that proves the action worked (`urlContains`, `visible`) —
  asserted at record time so a failed click can't produce a lying video.
- Pick the voice up front with `voiceId` (list them: `DemoTape --voices`).

## 4b. Pacing and attention (make it feel like a demo, not a screen-share)

A correct demo can still be a bad demo if it's slow or out of sync. Three rules, learned the hard
way:

- **Show it, then talk over it (reveal-early).** The thing the line describes must be on screen
  *while* it's spoken. Navigation and scrolling are REVEAL actions — the driver runs them at the
  start of a scene, so "here's the llms.txt" shows the page immediately. Only *announced
  interactions* (a click you narrate) should LEAD the line. Never let the voice describe a page that
  appears seconds later.
- **Keep it fast.** Short lines, one idea per scene, constant motion. A single line droning over a
  static page for 10s reads as sluggish. Prefer several ~6–9s scenes with a visible change in each
  (navigate, scroll to the next section, zoom on a detail) over one long static shot.
- **Direct attention with zoom.** DemoTape auto-zooms on real clicks. Add an emphasis click
  (`osClick: true`) on the exact element the line is about — a heading, a button, a value — so the
  viewer's eye goes where the words go. Click **non-navigating** elements (headings, labels) for
  pure emphasis; use real navigations for flow. This is the difference between "the page is up" and
  "look *here*."
  - Requirement: synthetic OS clicks need **Accessibility permission** granted to the terminal/app
    running the driver (System Settings → Privacy & Security → Accessibility). Without it the clicks
    silently no-op (no zoom). Verify it worked by checking the recording's `.source/*.events.json`
    has a non-empty `clicks` array; if it's empty, the grant is missing.

## 5. Rehearse headlessly

Before recording, run the exact steps + assertions in a headless browser (no DemoTape recording).
This validates selectors, expansions, inputs, and the success signal in seconds. Only record once
the rehearsal passes. If the app is **stateful** (creating something that then exists), reset it
between rehearsal and the real take (restart the in-memory backend) so the demo starts from a clean
state — otherwise the second run sees a different UI.

## 6 & 7. Record, voice, and verify

Run the driver against a running DemoTape (`node driver.mjs <config>`). It records the browser
region, lays each line at its scene's moment, renders, then verifies:
- **Assertions** (deterministic, from `expect`) must pass.
- **Vision verification**: a model checks each scene's end-frame matches the line (result-aware — a
  "I'll sign in" line with a dashboard screenshot passes; it fails only on error/blank/wrong-app).
On failure it retries (bounded) or, for stateful demos (`maxAttempts: 1`), fails loudly with a
report rather than retrying into a polluted state. It writes `demo-report.json` beside the video and
only presents a demo that passed.

## 8. Hand back

Give the user the final `…voiceover.mp4` path, the verification result, and one or two honest notes
on what a second pass would improve. If they dislike the voice, you don't re-record — see the
`revoice` command in `references/demotape-driver.md`.

## Anti-slop checklist

- [ ] Every narration claim maps to real app behavior (no invented capabilities).
- [ ] Every typed input is valid per the schema/validator (not a fixture), proven once before scripting.
- [ ] Rehearsed headlessly; all assertions passed before recording.
- [ ] Stateful demos start from a reset/clean state.
- [ ] Final `demo-report.json` shows assertions + verification all passed.
- [ ] Reveal-early: every page/section is on screen while its line is spoken (no late reveals).
- [ ] Fast pace: short lines, a visible change each scene; no long static shots.
- [ ] Attention: an emphasis click zooms the focal element (and `clicks` in events.json is non-empty).

## References

- `references/demotape-driver.md` — DemoTape control surface, driver config schema, CLI hooks
  (`--tts`, `--voiceover-timeline`, `--verify`, `--cursor`), voices, and the `revoice` command.
- `references/grounding-a-codebase.md` — using a code graph + schema-as-truth to find valid inputs,
  the local-stack bring-up playbook, and progressive-disclosure UI handling.
