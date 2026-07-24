# The `record-verified-demo` skill

This is the **AI-led way to make a demo** — instead of DemoTape handing you a prompt to paste, your
coding agent installs this skill and drives the whole thing: it understands your app, stands up its
local stack, discovers the real flow and valid inputs from the code, scripts scenes, records with
DemoTape + a synced ElevenLabs (or local) voiceover, and **verifies the output matches the script**
before showing it — like a test suite gating a release.

## Install

From a clone of the DemoTape repo:

```bash
# Claude Code (global — ~/.claude/skills)
tools/demo-driver/skill/install.sh

# Kiro (this workspace — .kiro/steering)
tools/demo-driver/skill/install.sh --kiro

# Any other agent that reads a skills directory
tools/demo-driver/skill/install.sh --dir /path/to/skills
```

The skill carries only the **instructions**. The driver it runs lives in this repo at
`tools/demo-driver/driver.mjs`, so keep your DemoTape checkout and run demos from it.

## Use

Ask your agent, in a checkout of the app you want to demo:

> Record a verified demo of &lt;feature&gt; in this app.

It will follow the skill: understand → stand up the stack → discover the real flow → script →
rehearse headlessly → record + voice → verify → hand back the video, the `demo-report.json`, and
what it would tighten.

## What's inside

- `record-verified-demo/SKILL.md` — the workflow (the cardinal rule: **be real, not plausible**).
- `record-verified-demo/references/demotape-driver.md` — the driver's config, timing model,
  attention gestures, and provider/voice options.
- `record-verified-demo/references/grounding-a-codebase.md` — how to find the true flow and valid
  inputs from routes/schema/validators (never from fixtures).

## Prerequisites

- DemoTape installed (`./build-app.sh release`) with Screen Recording granted, and for auto-zoom,
  Accessibility granted to the app.
- Node + Playwright for the driver (`cd tools/demo-driver && npm install`).
- A voice: an ElevenLabs key, **or** a local TTS server (see [`tools/tts-shim`](../../tts-shim)).
