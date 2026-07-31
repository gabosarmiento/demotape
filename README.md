<div align="center">

<img src="media/logo.png" alt="DemoTape" width="200">

# DemoTape

**Make a great demo of your app — fast, with your coding agent.**

Describe the feature; your agent (Kiro, Claude Code, Codex…) reads the code, runs the app, records the
flow, narrates it, and polishes — captions, voiceover, another language, a vertical cut. Or record it
yourself and let DemoTape do the styling. Local-first, no account, free and open source.

[![Download](https://img.shields.io/github/v/release/gabosarmiento/demotape?label=download&color=DC5050)](https://github.com/gabosarmiento/demotape/releases/latest)
[![Platform](https://img.shields.io/badge/macOS-12.3%2B-211E17)](https://github.com/gabosarmiento/demotape/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-832B72)](LICENSE)
[![Stars](https://img.shields.io/github/stars/gabosarmiento/demotape?style=flat&color=6464A0)](https://github.com/gabosarmiento/demotape)

</div>

Runs on **macOS 12.3+** (Intel or Apple Silicon) — including older Macs like Monterey 12.7.6.

> Free forever — no account, no license, no upsell. If it's useful,
> [**★ star the repo**](https://github.com/gabosarmiento/demotape) — that's how I'll know what to build next.

---

## Why this exists

My Mac is old, and the modern screen-recording tools have dropped support for it. So I vibecoded my
own with Claude — Apple frameworks only, no dependencies, so it runs on machines the newer apps have
left behind (macOS 12.3+, back to Monterey). There's a modest Windows version too.

The design goal was **no timeline editor and no fiddling** — I want the result, not another editing
suite. One command starts the recording; **⇧⌘S** stops it. That raw take becomes the source file, and
everything else is *derived* from it, so I never re-record just to change how it looks. Better still, I
can tell my coding agent "build me a demo of this feature from the folder I'm working in" and watch the
result — and when I need a caption, a voiceover, or a web export, each is one plain step.

It's for **developers and vibecoders who need a demo today** — of a feature, a side project, a launch,
a pull request — without a pile of subscriptions or an afternoon of editing.

## What you can make

- **Product & feature demos** — the agent drives your app and narrates what it's doing.
- **Launch clips & social cuts** — vertical (9:16), square (1:1), captioned for muted autoplay.
- **Talking-head / webcam videos** — a built-in teleprompter that never appears in the recording
  (great for a YC application or an intro).
- **Localized versions** — re-voice the same footage in another language, no re-recording.
- **Proof that a change actually works** — a *verified* demo of a pull request, with a per-scene
  pass/fail. See [Verified demos](#verified-demos-one-use-case) — one use case, not the whole point.

## How the agent builds a demo

```
describe the feature
        ↓
run the real app               launch it locally, the way a user would
        ↓
perform the flow               drive the UI, narration synced to each action
        ↓
record & style                 auto-zoom, smooth cursor, captions, voiceover
        ↓
check it (optional)            verify each scene shows what the narration says
        ↓
hand back the video            plus a per-scene report, if you asked to verify
```

The reason the checking matters: it keeps the demo **honest**. A take that shows the wrong thing
fails loudly and reports why, instead of being quietly trimmed until it looks clean. So the polished
video is a real recording of the app working — not an edit that papers over a broken step.

When you ask for verification, two independent checks run, and they answer different questions:

| Check | What it is | What it catches |
|---|---|---|
| **Assertions** | Deterministic post-conditions you declare per scene (`urlContains`, `visible`, `value`) | A click that didn't land, an input that didn't take, a page that never arrived |
| **Scene verification** | A vision model compares each scene's settled frame against its narration line | The flow "worked" but showed an error, a blank state, or the wrong screen |

Verification is honest about its own failure mode. There are **three** outcomes, not two:

| Outcome | Exit | Meaning |
|---|---|---|
| `verified` | 0 | assertions and scene verification both passed |
| `unverified` | 2 | something genuinely contradicts the script — fix it |
| `inconclusive` | 3 | assertions passed but the vision gate could not run (e.g. provider rate limit) — review by hand |

An `inconclusive` result is never presented as a pass.

## Verified demos (one use case)

Because DemoTape can *check* a demo, it doubles as a way to prove a change works — useful when the
code was written by an agent and someone has to trust it. Ask for a verified run and you get the
video plus a `demo-report.json` beside it: the overall verdict (`ok` / `assertionsOk` / `verifyOk`),
a per-scene assertion result, and per-scene vision verdicts with timestamps, the reason given, and
the narration line each frame was judged against.

A tiny example — the agent claims "bulk CSV and PDF export works," so the demo exercises it:

```
SCENE 01  Select 200 report rows            PASS
SCENE 02  Export selected rows as CSV       PASS
SCENE 03  Export selected rows as PDF       PASS
```

You get a narrated recording of that flow running against your code, plus the verdicts that back it
up. Attach it to a PR, a ticket, or a review. (Automatically wiring this into pull requests, and
tagging the report with the branch and commit, is on the [roadmap](#where-it-could-go) — today you
run it and attach it yourself.)

Also written beside the video: `verify-scenes.json` (the moments the gate photographed, to re-run the
check on the same frames), `timeline.json` (scene offsets, so narration can be re-voiced without
re-recording), and `recipe.json` (every styling choice, so the video can be re-derived from the raw
take).

---

## Current capabilities

Generated from what's in this repository today.

### Available now

**Agentic recording**
- A skill that drives the whole pipeline from a prompt: understand the app, script scenes, drive the
  browser, record, narrate, verify ([`SKILL.md`](tools/demo-driver/skill/record-verified-demo/SKILL.md))
- Headless rehearsal (`--rehearse`) — validates every step and assertion with no recording, so a
  broken take never gets recorded
- Per-scene assertions and a vision verification gate, with the three-state outcome above
- `demo-report.json`, `verify-scenes.json`, `timeline.json`, `recipe.json` written beside the video

**Recording**
- Full screen, selected area (lockable in place), or **webcam only** at 1080p
- Auto-styled render: spring-eased auto-zoom on real activity, smooth synthetic cursor, click
  ripples, keyboard-shortcut badges, framed backgrounds, webcam PiP, branding watermark
- Teleprompter that scrolls on screen but stays out of the recording
- Countdown, mic/camera toggles, audio enhancement and noise suppression

**Post-production** (all reachable headlessly)
- `--render` / `--recipe` / `--show-recipe` — re-derive the styled video from the raw take; revise
  the look from a one-key patch instead of re-recording
- `--reframe` — vertical/social cuts (9:16, 1:1, 4:5) via a planned camera that crops the sides and
  fills the height, holds shots, follows typed text, and routes long moves through an overview;
  `--debug` draws the camera rect on the landscape footage
- `--tighten` — Auto-Cut: remove silence, adjust pace
- `--captions` / `--burn` / `--srt` — transcribe, edit, burn subtitles (14 styles incl. word-by-word)
- `--tts` / `--voiceover` / `--voiceover-timeline` / `--tag` — narration, laid at scene offsets;
  `narrate` and `revoice` add a language or swap the voice from the same footage, no re-record
- `--verify` / `--frame` / `--cursor` — the verification gate, still grabs, cursor control
- `--transcode` / `--publish` / `--gif` — web tiers, poster, embed snippet, GIF

**Local and offline**
- Provider-pluggable STT and TTS: hosted, any OpenAI-compatible endpoint, or fully local
- `scripts/local-ai.sh` — one command sets up local narration and captions with **no API keys**
- Recorder, renderer and exporter make **no network calls** at all

### Experimental

- **Avatar** — a photorealistic presenter lip-synced to your voiceover. Cloud, paid, shows cost
  before running.
- **AI Director** (`--brief`, `--template`) — reasons over transcript and activity to propose an edit.
- **Windows port** ([`windows/`](windows/), C# · .NET 8 · WinUI 3) — traditional recording and the
  styled render work; the agentic, captions, voiceover and avatar features are macOS-only.

### Planned

Not implemented. Do not expect these to work yet.

- GitHub pull-request bot that attaches the video and verdicts automatically
- Jira and Linear acceptance criteria as the eval input
- CI-triggered evaluations
- Shared team evidence library
- Consolidated `eval.json` manifest with branch, commit, and expected-vs-observed state
- Managed cloud services (hosted captions/voiceover without your own key)

---

## Quick start

### 1. Install

**Requirements:** macOS 12.3+ (Intel or Apple Silicon).

**Download.** Grab `DemoTape-<version>.dmg` from
[Releases](https://github.com/gabosarmiento/demotape/releases/latest) and drag it into
**Applications**. It's Developer-ID signed and notarized, so it opens normally. Run it from
**/Applications** so macOS remembers Screen Recording permission.

**Or build from source.**

```bash
./create-identity.sh    # one-time signing identity (keeps permissions across rebuilds)
./build-app.sh release  # build, sign, install to /Applications
```

No Xcode project, no third-party dependencies — Apple frameworks and `swift build`. See
[`AGENTS.md`](AGENTS.md) for build and verify steps.

### 2. Grant permissions

**First launch** asks for **Screen Recording**: click Allow, tick DemoTape in System Settings, then
**Quit & Reopen** (macOS only applies it on relaunch). Microphone, Camera and Accessibility are
requested only when a feature needs them.

### 3. Record something (30 seconds)

Click the menu-bar icon (**⇧⌘S**), pick **Full Screen** or an area, press **Start**, do something,
press **Stop**. DemoTape writes a styled video to `~/Movies/DemoTape/`.

### 4. Set up narration and captions

These are the only features that need a model. Three options:

**Local, no API key** (needs Docker):

```bash
scripts/local-ai.sh          # pulls Kokoro + Whisper, points DemoTape at them, proves it works
scripts/local-ai.sh --status # what's running
scripts/local-ai.sh --uninstall
```

It verifies itself end to end: synthesizes a clip with the local TTS, transcribes it back with the
local STT, and prints what it heard. No key is written and the Keychain is untouched.

**Your own hosted key** — add it in **AI Settings**; it's stored in the macOS Keychain.

**Any OpenAI-compatible endpoint** — see [`tools/tts-shim`](tools/tts-shim).

### 5. Let your agent record a verified demo

Install the skill:

```bash
tools/demo-driver/skill/install.sh              # Claude Code (~/.claude/skills)
tools/demo-driver/skill/install.sh --kiro       # Kiro (this workspace)
tools/demo-driver/skill/install.sh --dir <path> # any other skills directory
```

Then, in a checkout of your app, ask your agent:

> Open the application from the current branch. Verify that a user can select multiple reports,
> export them as CSV, and export them as PDF. Record the full flow, narrate the result, and show a
> verdict for each expected scene.

Or more simply:

> Record a verified demo of &lt;feature&gt; in this app.

You get a `…voiceover.mp4` and a `demo-report.json` with a per-scene verdict. In the app it's the
first menu item: **Let Your Coding Agent Record a Demo…**

Driving the driver directly:

```bash
cd tools/demo-driver && npm install
node driver.mjs <config>.json --rehearse   # validate steps + assertions, headless, seconds
node driver.mjs <config>.json              # record, narrate, verify
node driver.mjs narrate <recording> lines-es.json   # another language, same footage
node driver.mjs revoice <recording> <voiceId>       # swap the voice, keep the sync
```

---

## See it

This demo was made by a coding agent — scripted, recorded, narrated and verified — then sped up and
captioned, all from prompts:

[![Watch the demo](media/demo-poster.jpg)](https://github.com/gabosarmiento/demotape/releases/download/v7.0.0/demotape-demo.mp4)

▶ [**Watch the 2-minute demo**](https://github.com/gabosarmiento/demotape/releases/download/v7.0.0/demotape-demo.mp4)

<!-- INLINE PLAYER: paste a github.com/user-attachments/assets/<uuid> URL on its own line here.
     Committed files (raw/blob URLs) do NOT embed — only attachment URLs do. Mint one by dragging
     an mp4 into a NEW ISSUE comment box on github.com (issue uploads allow larger videos than the
     README editor's ~25MB), copy the URL it inserts, then cancel the issue and paste it here. -->


<!--
  To play INLINE (like DeepFilterNet's README), GitHub needs an "attachment" URL, which is only
  minted by uploading through the web UI — a release-download or raw URL will NOT render a player.
  One-time step: edit this README on github.com, drag demotape-demo.mp4 into the editor, and GitHub
  inserts a line like  https://github.com/gabosarmiento/demotape/assets/<id>/<uuid>  — replace the
  poster block above with that bare URL on its own line and the player embeds directly.
-->

A real run, start to finish, driven entirely by prompts:

1. **Understand the app.** The agent read a codebase (KIFF, an AI-governance platform), installed the
   skill, and worked out what was worth showing and how to reach it.
2. **Script and record.** It stood up the local stack, wrote the scenes, drove the browser, and
   recorded — narration synced to each action.
3. **Verify.** Every scene was checked against what was actually on screen; a take that showed the
   wrong thing fails loudly instead of shipping.
4. **Polish, by prompt.** Sped up to 1.25×, captions burned in, then the whole thing re-voiced in
   **Spanish** and **French** — same footage, new narration and subtitles, no re-recording.

---

## Record it yourself

Not every video is an agent run.

### Webcam only

**Webcam Only** is a first-class capture mode — pick it from the menu-bar icon or the floating bar's
**•••** — and DemoTape records just your camera at 1080p, a clean talking-head. A near-full-screen
live preview makes it obvious the camera is the whole video, and an optional teleprompter scrolls on
screen for you but **never appears in the recording** (it captures the camera, not the screen).
Mirror the image with **Mirror camera**, and clean the mic with **Enhance audio** and **Noise
suppression**. The result is a normal recording, so Captions, Voiceover and Web Publish all work on it.

The agent can write the script and run the teleprompter for you:

> Help me make a 1-minute YC application video. Write it to sound natural when spoken (per
> ycombinator.com/video), load it into the teleprompter, and tell me when to start.

It loads the teleprompter, says "ready when you are", counts 3-2-1, and records you to camera.

### Screen recording

Pick **Full Screen** or an area and a floating bar appears: Start/Stop, a timer, a blinking tally
light while rolling, mic and webcam toggles, and a **•••** for what you set before a take —
background, branding, teleprompter, auto-zoom. Pick an area and you can **lock** it in place to click
and scroll the app beneath while framing your shot.

Then, under **After Recording**, each step opens a source→result window with a **Generate preview**:

- **Auto-Cut / Auto-Edit** — trim silences and tighten pace, or re-edit with a paced look. Local.
- **Captions** — transcribe, edit the lines, burn them in. Includes word-by-word social styles.
- **Voiceover** — turn a script into narration; add another **language** on the same timings.
- **Avatar** — a photorealistic presenter that lip-syncs to your voiceover (cloud, shows cost first).
- **Web Publish** — lightweight MP4 tiers, a poster, an embed snippet, and a GIF.

Captions, Voiceover and Avatar can also hand the job to your coding agent with **Copy prompt for
your agent**.

---

## Local-first and privacy

- **Recordings stay on your Mac.** The recorder, renderer and exporter make **no network calls**.
  Your screen recording is never uploaded.
- **No account.** No sign-up, no license key, no telemetry gate.
- **AI steps are opt-in.** They only run when you turn them on, and only send what the step needs:
  captions send the audio, voiceover sends the script, verification sends the frames it judges.
- **Bring your own keys** (stored in the macOS Keychain), or run **fully local** models with
  `scripts/local-ai.sh` — no key, nothing leaving the machine.
- **MIT licensed**, so you can read exactly what it does.

The cloud **Avatar** feature is the exception: it uploads to a third-party provider by design, is
clearly marked, and shows its cost before running.

---

## About

DemoTape came out of building [kiff.dev](https://kiff.dev) and needing to demo it constantly. It's a
standalone, self-contained app now — it needs nothing from Kiff and works with any codebase and any
coding agent.

---

## Where it could go

DemoTape is free and stays free. There's **no waitlist and no pricing** — the honest signal is a star.

- **Use it today.** It's done and it works. If it saved you an afternoon, that's the whole point.
- **Want it to become more?** If you think this should be a real product your team relies on,
  [**★ star the repo**](https://github.com/gabosarmiento/demotape). Enough interest and I'll build the
  bigger pieces below — no sign-up, no "request access."
- **Buy me a coffee** if it earned one: [buymeacoffee.com/gabosarmiento](https://buymeacoffee.com/gabosarmiento).
- **Want it for your team, or a hand setting it up?** Open an
  [issue](https://github.com/gabosarmiento/demotape/issues) or reach out — I'll help, and if there's
  real demand the team features get built (not before).

Things I'd build if the interest is there — clearly **not implemented yet**:

- Save a verified flow as a reusable check and re-run it against any branch (a demo that doubles as a
  regression test).
- Attach the video + verdicts to a pull request automatically, tagged with the branch and commit.
- Read acceptance criteria straight from a Jira or Linear ticket.
- A shared, searchable history of runs for a team.

---

## Contributing

Bug reports and pull requests welcome — including PRs generated by a coding agent. See
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the process and review standards, and
[`AGENTS.md`](AGENTS.md) for the build, the hard constraints (macOS 12.3 target, Apple frameworks
only, no third-party dependencies, local-by-default), the headless hooks for verifying render
changes without granting Screen Recording, and troubleshooting.

```bash
swift build -c release   # compile
swift test              # 422 tests: pure logic, no GUI, no network
```

## License

MIT — see [LICENSE](LICENSE). A dependency-free implementation of its own; built by studying, not
copying, other open-source recorders.
