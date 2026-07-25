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

## Pointing it at your own app

Copy `demo.example.json`, set `url` to your app (local or deployed), and script the steps you want
shown — the flow a new user would be walked through, ending on the thing that proves it worked. Give
each scene the line you'd say out loud while it happens. That's the "idea → script → finished demo"
loop end to end.

Name your own configs `demo-<something>.local.json`: that pattern is gitignored, because a real config
carries your hosts, routes, selectors and page copy, and this repo is public.

If your app is behind a login, sign in once into a reusable profile instead of typing credentials on
camera:

```bash
node driver.mjs signin https://app.example.com/home --profile .profiles/myapp
# then in the config:  "userDataDir": ".profiles/myapp"
```

Rehearse before you record — it runs every step and assertion headlessly in seconds:

```bash
node driver.mjs demo-myapp.local.json --rehearse
```

> Note: narration is laid over the whole clip, not word-synced to each click. Pace the steps
> (`stepPauseMs` / per-step `pauseMs` / `wait`) so the visuals roughly track the narration.
