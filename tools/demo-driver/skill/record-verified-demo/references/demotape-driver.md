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
  The driver saves the spec it used as **`verify-scenes.json` beside the video**, so a gate that
  couldn't run (rate limit) can be re-run later on the exact same moments:
  `DemoTape --verify <…voiceover.mp4> <recording-dir>/verify-scenes.json`.
  Do NOT rebuild a spec from `timeline.json` — those are scene *starts* (for laying the voice), while
  the gate photographs each scene's **settled** moment. Judging "now I'll type this" against the
  frame from before it was typed fails a take that was fine.
- `DemoTape --frame <video> <t[,t2,…]> <out.png-or-dir> [maxHeight]` — grab stills to LOOK at.
  Whether the pointer landed on the button, whether the zoom framed the right thing, whether text
  overlaps — visual facts a log can't answer. Pair it with `--verify` on a hand-written spec to check
  one specific thing ("the pointer is ON the Grant button, not in the gap beside it").
- `DemoTape --cursor move|click <x> <y>` — move the real cursor (visible in capture) / click.
- `DemoTape --render`, `--transcode`, `--captions`, `--burn`, `--publish`, etc. (see AGENTS.md).
- `DemoTape --show-recipe [<recording-dir>]` — print the render recipe (all valid field names).
- `DemoTape --render <raw.mov> <out.mp4> --recipe <patch.json>` — **revise without re-recording.**
  The raw take + `events.json` are ground truth, so the styled video is re-derivable; `recipe.json`
  beside the recording captures the look. Fields are optional, so a patch can be a single key.
  Unknown keys are reported, not ignored. See the Revise phase in SKILL.md.

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

`osClick` is **on by default** (opt out with `"osClick": false`, which you almost never want).
`click` steps fire a real OS click through the *running app* — `demotape://cursor/click` — so the
click lands in `events.json` and drives the auto-zoom. Because the running app holds the
Accessibility grant, the terminal needs no permission of its own.

Use it on the exact element the line describes; click **non-navigating** elements (headings, labels)
for pure emphasis. Confirm the zoom fired: `.source/*.events.json` must have a non-empty `"clicks"`
array. Earlier demos with `osClick: false` verified perfectly and were still one motionless shot,
because Playwright's synthetic clicks are invisible to the global event monitor.

Moves are animated over `moveMs` (default 520) via `demotape://cursor/glide` — eased, slightly
arced, with a small overshoot on long trips.

**Point at words, not at boxes.** Targeting a container is how a demo ends up clicking nothing: a
card or a list is mostly padding, so its geometric centre is often blank. The driver resolves a
target that paints no text of its own down to the first visible descendant that does, and re-measures
the target immediately before pressing (a page can reflow during the half-second glide). Both help,
but neither rescues a selector like `.approval-list` when you meant `.approval-action` — name the
element whose words the line is about. And on a form, click the **button**
(`form.x button.btn-primary`), never the surrounding form.

### The pointer changes shape

The recording samples the pointer the system was actually showing — arrow, hand over a link or
button, text bar over a field — and the render draws that shape (enlarged, `cursorScale` in the
recipe). Nothing to configure; it follows from putting the cursor over real controls, which is
another reason to point at elements rather than empty space. `demo-cursor-probe.json` checks it with
no app, no network and no account; kinds land in `.source/*.events.json` as `cursor[].kind`.

### Selector tips

- Prefer precise selectors: `button[type=submit]`, `button:has-text('Derive a control')`,
  `input[name=subject]`, `textarea[name=yaml]`. Avoid bare `text=Sign in` — it can match a heading.
- If an element is inside a collapsed panel, add an `expand` step targeting the container
  (`details.studio-yaml-panel`) before filling it.

## The vision gate costs tokens, and images are expensive

One vision call per scene, and a screenshot is not a cheap prompt: hosted providers bill an image as
512-pixel tiles, and the **`-mini` vision models charge each tile many times over** — a 768px-tall
frame is ~37k tokens on `gpt-4o-mini` versus ~1k on `gpt-4o`. Eleven scenes fired back-to-back ask
for ~400k tokens inside a minute against a 200k-per-minute budget, which is why a good take used to
come back `INCONCLUSIVE — provider rate limit (429)`.

The gate now paces itself against that budget (spreading it evenly, ~11s a scene on a mini model) and
retries with the provider's own message attached, so a 429 tells you whether to wait or to top up.
Knobs: `DEMOTAPE_VERIFY_TPM` (default 200000, `0` disables pacing on a high-tier key) and
`DEMOTAPE_VERIFY_GAP_MS` (floor between calls). Pointing the captions/vision model at `gpt-4o`
instead of `gpt-4o-mini` makes the gate both faster and cheaper for images.

## Run

```bash
node driver.mjs demo-myapp.local.json    # record + voice + verify; writes demo-report.json
node driver.mjs demo-myapp.local.json --rehearse   # steps + assertions only, headless, seconds
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
