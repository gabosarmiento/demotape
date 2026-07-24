# DemoTape demo driver (Playwright)

An **external** tool that produces an auto-narrated DemoTape demo from a config — no manual
recording, no timeline editing. It is deliberately **not** part of the DemoTape app (the app stays
Apple-frameworks-only and dependency-free); this driver is a standalone Node + Playwright tool.

## What it does

Given a config (target URL, viewport, on-screen steps, narration), one command:

1. launches a **headed** Chromium at a known screen rectangle,
2. tells the running DemoTape to record exactly that rectangle (`demotape://record/start`),
3. drives the browser through your steps,
4. stops recording — DemoTape auto-renders (you'll see the progress HUD),
5. lays an **ElevenLabs voiceover** over the result (`DemoTape --voiceover`),
6. opens the finished `…voiceover.mp4`.

The app itself needs no code from here — it's driven through the `demotape://` URL scheme and the
`~/Movies/DemoTape/.demotape/control.json` status file.

## Prerequisites

- DemoTape installed and **running** in `/Applications`, with Screen Recording granted.
- Your ElevenLabs key saved in DemoTape (AI Settings), or exported as `DEMOTAPE_ELEVEN_KEY`.
- Node 18+.

## Setup

```bash
cd tools/demo-driver
npm install            # also downloads the Chromium build (postinstall)
```

## Run

```bash
node driver.mjs demo.example.json     # generic smoke test against playwright.dev
node driver.mjs my-demo.json          # your own config
```

## Config

```jsonc
{
  "url": "http://localhost:3000/dashboard",
  "appMode": true,                       // clean app window (no tabs/omnibox)
  "viewport": { "x": 120, "y": 90, "width": 1280, "height": 800 },
  "stepPauseMs": 1000,                   // calm pacing between steps
  "voiceId": "",                         // ElevenLabs voice id (blank = default)
  "narrationFile": "narration.txt",      // or inline "narration": "..."
  "steps": [
    { "action": "wait",   "ms": 1500 },
    { "action": "click",  "selector": "text=Sign in" },
    { "action": "fill",   "selector": "#email", "text": "demo@acme.dev" },
    { "action": "press",  "key": "Enter" },
    { "action": "waitFor","selector": "text=Studio" },
    { "action": "scroll", "y": 600 }
  ]
}
```

Supported actions: `goto`, `wait`, `click`, `fill`/`type`, `press`, `hover`, `scroll`, `waitFor`,
`narrate` (a no-op marker).

## Pointing it at kiff-cloud

Run the dashboard locally (or use a deployed URL), set `url` to it, and script the steps you want
shown (sign in → Studio → author a domain → open a receipt). Put the narration in `narration.txt`.
That's the "idea → script → finished demo" loop end to end.

> Note: narration is laid over the whole clip, not word-synced to each click. Pace the steps
> (`stepPauseMs` / per-step `pauseMs` / `wait`) so the visuals roughly track the narration.
