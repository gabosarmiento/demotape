# DemoTape control surface + demo-driver reference

DemoTape is the recorder; the Node/Playwright **demo-driver** (in `tools/demo-driver/`) is the
external brain. The app stays Apple-frameworks-only; all orchestration lives in the driver.

## Prerequisites

- DemoTape installed in `/Applications` and **running**, with Screen Recording granted.
- ElevenLabs key saved in DemoTape (AI Settings), or exported as `DEMOTAPE_ELEVEN_KEY`.
- For verification: an OpenAI-compatible key saved (captions key) or `DEMOTAPE_STT_KEY`.
- `cd tools/demo-driver && npm install` (downloads Chromium).

## Control surface (how the driver talks to DemoTape)

A running DemoTape handles `demotape://` URLs (open them with `/usr/bin/open`) and publishes state
to `~/Movies/DemoTape/.demotape/control.json` (poll it):

- `demotape://record/start?mode=area&x=&y=&w=&h=&countdown=0` — record a screen rectangle now.
- `demotape://record/start?countdown=0` — full screen.
- `demotape://record/stop` — stop; DemoTape auto-renders the styled `.mp4`.
- `control.json`: `{ "state": "idle|countdown|recording|rendering", "lastOutput": "<path>" }`.

Loop: launch a headed browser at a known rectangle → `start` that rectangle → drive → `stop` →
poll `state:"idle"` → read `lastOutput` (the styled video).

## Headless CLI hooks (on the DemoTape binary)

- `DemoTape --voices` — list ElevenLabs voice ids + labels.
- `DemoTape --tts <script.txt> <out.mp3> [voiceId]` — synthesize narration only.
- `DemoTape --voiceover <video> <script.txt> [voiceId]` — one narration block over a video.
- `DemoTape --voiceover-timeline <video> <spec.json>` — lay MANY clips at offsets (scene sync).
  spec: `{"clips":[{"audio":"/a.mp3","at":0.0},{"audio":"/b.mp3","at":6.2}]}`.
- `DemoTape --verify <video> <spec.json>` — vision-check each scene's frame vs its line; exits 0 if
  all pass, 2 otherwise. spec: `{"scenes":[{"at":3.8,"say":"…"}]}`.
- `DemoTape --cursor move|click <x> <y>` — move the real cursor (visible in capture) / click.
- `DemoTape --render`, `--transcode`, `--captions`, `--burn`, etc. (see repo AGENTS.md).

## Driver config schema (`demo-*.json`)

```jsonc
{
  "url": "http://localhost:8081/sign-in",   // first page to load
  "viewport": { "x": 120, "y": 80, "width": 1280, "height": 860 }, // screen rect (points)
  "voiceId": "XrExE9yKIg1WjnnlVkGX",         // ElevenLabs voice (Matilda). "" = default
  "stepPauseMs": 900,                         // pacing between steps
  "actionLeadFraction": 0.7,                  // fraction of the line spoken before the action fires
  "tailMs": 1600,                             // recording tail so the last line isn't clipped
  "showCursor": true,                         // move the real cursor to targets (visible)
  "osClick": false,                           // true = OS-level clicks (triggers zoom; needs Accessibility)
  "maxAttempts": 1,                           // retries on failure; use 1 for STATEFUL demos
  "verify": true,                             // run the vision verification gate
  "scenes": [
    {
      "say": "Okay, let me show you how to create a domain. First, I'll sign in.",
      "steps": [
        { "action": "fill", "selector": "input[name=subject]", "text": "dev-user" },
        { "action": "click", "selector": "button[type=submit]" }
      ],
      "expect": { "urlContains": "/dashboard" }
    }
  ]
}
```

### Step actions

`goto {url}` · `wait {ms}` · `click {selector}` · `fill`/`type {selector,text}` ·
`press {key}` · `hover {selector}` · `scroll {y}` · `waitFor {selector}` ·
`expand {selector}` (force a `<details>` open — for progressive-disclosure UIs) ·
`narrate` (no-op marker). Steps default to an 8s timeout; override with `timeout`.

### `expect` (record-time assertion — proves the action worked)

`{ "urlContains": "/path" }` · `{ "visible": "<css-or-text-selector>" }` ·
`{ "text": "some text" }`. On a failed assertion the driver **fail-fasts** (aborts the take and
retries or reports) instead of recording a broken demo.

### Timing model (reveal vs commit)

The driver classifies each scene's steps so the visuals sync with the narration:
- **Reveal** (`goto`, `scroll`, `expand`, `waitFor`, `hover`) run at the **start** of the scene —
  the page/section is shown while the line is spoken.
- **Commit** (`click`, `fill`, `type`, `press`) **lead** the narration (fire partway through, by
  `actionLeadFraction`, default 0.7) — the announced interaction lands where the words point, and a
  click triggers auto-zoom.
Per-scene override: `"leadFraction": 0.5`.

### Emphasis clicks → auto-zoom

With `"osClick": true`, `click` steps fire a real OS click (via `--cursor click`) so DemoTape
auto-zooms the target. Use this on the exact element the line describes. Click **non-navigating**
elements (headings/labels) for pure emphasis. Requires **Accessibility permission** for the terminal
running the driver; without it clicks silently no-op. Confirm zoom fired: the recording's
`.source/*.events.json` should have a non-empty `"clicks"` array.

### Selector tips

- Prefer precise selectors: `button[type=submit]`, `button:has-text('Derive a control')`,
  `input[name=subject]`, `textarea[name=yaml]`. Avoid bare `text=Sign in` — it can match a heading.
- If an element is inside a collapsed panel, add an `expand` step targeting the container
  (`details.studio-yaml-panel`) before filling it.

## Run

```bash
node driver.mjs demo-kiff.json          # record + voice + verify; writes demo-report.json
```

Progress logs to `driver.log`. It opens the final `…voiceover.mp4` and exits non-zero if unverified.

## Swap the voice later (no re-recording)

Every recorded demo saves `timeline.json` (scene offsets + lines) beside the video. To change only
the voice while keeping perfect sync:

```bash
node driver.mjs revoice "<recording-folder-or-styled.mp4>" <voiceId>
```

It re-synthesizes each line with the new voice and re-lays them at the saved offsets. (Demos
recorded before timeline-saving have no `timeline.json` — re-run the driver once for those.)

To **preselect** a voice, set `voiceId` in the config. To pick from your account: `DemoTape --voices`.
