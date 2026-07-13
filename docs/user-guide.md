# DemoTape User Guide (v2)

DemoTape records your screen and auto-styles it into a polished demo. **v2** adds an opt-in AI
layer: **captions** and **voiceover**, using your own API keys. This guide covers the whole
flow, from recording to a captioned or narrated video.

> AI is **off by default**. With it off, DemoTape is fully local and makes no network
> requests. You turn it on and add your own keys in **AI Settings**.

---

## 1. Install & first run

```bash
./create-identity.sh      # one-time: stable signing identity for Screen Recording permission
./build-app.sh release    # build, sign, install to /Applications
open /Applications/DemoTape.app
```

A record icon appears in the menu bar. Run it from **/Applications** (macOS is unreliable
about Screen Recording permission for apps in Desktop/Documents).

On first record, grant **Screen Recording** (required). **Microphone**, **Camera**, and
**Accessibility** are requested only if you use those features.

---

## 2. Record

- **⇧⌘S** or the menu starts/stops recording after a 3-2-1 countdown.
- Choose **Record Full Screen** or **Select Recording Area…**. A floating **recorder bar**
  appears (Start/Stop, timer, mic + webcam toggles, cancel). It's draggable, and you can
  Tab/Enter through its buttons.
- For a region, the selected area stays on screen as an **adjustable frame**: drag inside to
  move it (hand cursor), drag an edge/corner to resize it (resize cursors). It locks and stays
  visible when recording starts, and never shows up in the capture.
- Toggle **Record Microphone**, **Record Webcam**, **Webcam Settings…**, **Background…**.
- On Stop, a styled `…styled.mp4` is written to `~/Movies/DemoTape/`.
- **Branding:** menu → **Branding Settings…** to upload a logo, drag it into place, and size it;
  **Enable Branding** watermarks your exports. **Recording Folder → Change Output Directory…**
  saves recordings wherever you like (remembered across launches). Config items are disabled
  while recording.

**Planning for AI:**
- Want **captions**? Record with the **microphone on** so there's speech to transcribe.
- Want a **voiceover**? Record **screen-only** (webcam off). A voiceover replaces the audio,
  so if you're visibly speaking on the webcam, your lips won't match the new voice.

---

## 3. Turn on AI (one time)

Menu bar → **AI Features → AI Settings…**

1. Tick **Enable AI features**.
2. **Speech-to-Text (Captions):** pick a **Provider** (OpenAI or Groq auto-fill the URL and
   model), paste your **API key**. Optional language hint (e.g. `en`).
3. **Voiceover (ElevenLabs):** paste your ElevenLabs **API key**.
4. **Save.**

Keys are stored in the macOS **Keychain** — never in files or preferences. Requests go only
to the provider you chose, with your key.

Supported STT providers and details: [`captions.md`](captions.md).

---

## 4. Captions

Menu bar → **AI Features → Generate Captions for Latest…**

1. DemoTape transcribes the audio (first time only — see caching below) and opens the
   **caption editor**.
2. Each line is an editable box that grows to fit the text. **Fix any wording**; timings stay
   as transcribed.
3. Then choose:
   - **Save** — writes `…styled.srt` and `…styled.vtt` next to the video (for players,
     YouTube, or the Web Publish `<video>` embed).
   - **Add to Video** — burns the captions into a new `…captioned.mp4` (bottom-center,
     rounded translucent box). Your original stays untouched.

**Transcribe once (no repeat charges).** The transcript is cached as `…transcript.json`
(and an existing `.srt` is reused). Re-opening the editor for the same recording is instant
and does **not** call the API again.

---

## 5. Voiceover

Menu bar → **AI Features → Generate Voiceover for Latest…**

1. The **script** box is pre-filled from the transcript if one exists. You can:
   - edit it,
   - type a fresh script, or
   - **Load Script…** a `.txt` (e.g. one you wrote with ChatGPT).
2. Pick a **voice** from your ElevenLabs account.
3. **Generate** → DemoTape synthesizes the narration and lays it over the video from the
   start, writing `…voiceover.mp4`.

**The winning workflow:** write the script first, record while pacing yourself to it, then
generate the voiceover. Because you authored the script to match what's on screen, the timing
lines up naturally — no editing required.

**Best for screen-only demos.** Voiceover replaces the audio, so avoid it when you're speaking
on camera (use captions on your real voice instead).

---

## 5a. Avatar presenter (HeyGen — opt-in, paid)

Turn a voiceover into a **photorealistic presenter** that lip-syncs to the narration and sits
in the **webcam circle**, wherever you dragged it. It's rendered by [HeyGen](https://heygen.com)
in the cloud and **metered**, so it's opt-in, needs its own key, and always asks you to confirm
the cost first.

**Setup:** menu → **AI Features → AI Settings…** → **Avatar Presenter** → paste your HeyGen key,
click **Test key** (it turns ✓ and saves).

**Generate:** menu → **AI Features → Generate Avatar Presenter for Latest…** (enabled once you
have a HeyGen key *and* a voiceover for the latest recording).

1. **Pick your presenter:**
   - **Upload a photo…** — a clear, front-facing photo of a face. DemoTape pads it with a bit
     of headroom so the framing isn't cropped, then HeyGen animates it.
   - **Library avatar** — choose one of HeyGen's stock avatars (the list loads on demand).
2. **Review the estimate.** DemoTape shows the narration length, an approximate **credit cost**
   and **render time**, and a note that longer clips cost and take proportionally more. You must
   **confirm** before anything is sent.
3. **Generate.** Only the **narration audio** — and your photo, if you uploaded one — is sent to
   HeyGen. The **screen recording is never uploaded.** DemoTape polls until the render is ready,
   downloads it, chroma-keys out the background, and composites a circular, lip-synced presenter
   into the webcam slot at your saved webcam position and size, writing a new video alongside the
   others.

**Sizing expectations.** Best for short clips: **ideal ~30s**, guidance up to **~2 minutes**.
Render time and cost scale with length (roughly ~20 credits/minute on the photorealistic engine),
so a 5-minute clip both costs and takes noticeably more — the confirmation dialog spells this out
before you commit.

**Re-generate later.** DemoTape keeps the `…voiceover.narration.m4a` sidecar after generation, so
you can produce a different presenter from the same narration without re-running voiceover.

**Tip:** the avatar drops into the webcam circle, so set its position and size first in
**Input → Webcam Settings…** — the presenter lands exactly where you'd place your live camera.

---

## 5b. Teleprompter

Menu → **Teleprompter → Teleprompter Settings…**

- **Script tab:** paste your text and pick a **Speed** (1× is a natural reading pace) or tick
  **Fit to a set duration**. **Test** previews the scroll live (not recorded).
- **Display tab:** choose which **edge** the strip sits on (top/bottom/left/right), shown on a
  diagram of the capture area.
- Enable it from **Teleprompter → Enable Teleprompter**. While recording, the script scrolls in
  that strip — **outside the recording**, so it never appears in the video. In full-screen a
  thin strip on the chosen edge is reserved (leave a little headroom in your content); in
  Select Recording Area mode it scrolls in the margin around your selection.

## 6. Auto-Cut & Speed Up (local, no AI)

Menu bar → **Auto-Cut & Speed Up Latest…**

- **Remove silent gaps** — scans the audio and cuts pauses longer than ~0.6s (keeping a little
  padding so cuts aren't abrupt), like the jump-cut feature in social video editors.
- **Speed** — 1.1× / 1.25× / 1.5×, with the voice kept natural (pitch preserved).
- **Create** writes a new `…tight.mp4`. Your original is untouched.

This is fully local — no network, no key, no cost. It's the fastest way to make a demo feel
snappy. Tip: run it, then **Web Publish** the result to shrink it for sharing.

## 6b. Recording-area presets & GIF export

- **Select Recording Area…** shows preset chips (4:5, 1:1, 16:9, 9:16, or Freeform). Click one
  and it drops a suggested, aspect-locked area — adjust with the handles, then record. The
  export is scaled to that platform's target size (e.g. LinkedIn feed → 1080×1350). Freeform
  lets you drag any area.
- **Web Publish** has an **Animated GIF** option (Smaller / Balanced / Sharp) that writes a
  looping `demo.gif` for dropping into a README with `![](demo.gif)`.

## 7. Output files

Everything lands next to the recording in `~/Movies/DemoTape/`:

| File | What it is |
|---|---|
| `…styled.mp4` | The auto-styled recording |
| `…styled.srt` / `.vtt` | Subtitle sidecars (from **Save**) |
| `…transcript.json` | Cached transcript (reused, no re-charge) |
| `…captioned.mp4` | Video with captions burned in (**Add to Video**) |
| `…voiceover.mp4` | Video with the AI narration |
| `…voiceover.narration.m4a` | Durable narration audio (kept for re-generating an avatar) |
| `…avatar.mp4` | Video with the HeyGen presenter composited into the webcam circle |
| `…tight.mp4` | Silence-cut / sped-up version (Auto-Cut & Speed Up) |
| `…-web/` | Web Publish output (per-tier MP4s + poster + `embed.html`) |

---

## 8. Costs & privacy

- Captions bill per minute of audio (a 2-minute demo is a fraction of a cent on OpenAI).
  ElevenLabs bills per character of narration. The **avatar presenter** is the priciest step —
  HeyGen meters it by rendered minute (roughly ~20 credits/minute on the photorealistic engine),
  which is why DemoTape shows an estimate and asks you to confirm before every generation. You
  pay each provider directly.
- Nothing is sent anywhere unless you enable AI and trigger an action, and then only to the
  provider you configured with your key. For the avatar, only the narration audio (and your
  photo, if uploaded) is sent — **never the screen recording**. No telemetry, no accounts.
  Verifiable in the source or with a firewall like Little Snitch.

---

## 9. Troubleshooting

- **AI menu items do nothing / ask you to open settings** — enable AI and add the relevant
  key in AI Settings.
- **"The recording has no audio track"** — captions/voiceover need audio; record with the
  microphone on (or provide a script for voiceover).
- **Captions "HTTP 401/404"** — wrong key for the URL (an OpenAI key won't work on the Groq
  URL), or a Base URL that doesn't end at `…/v1`.
- **Voiceover feels off against a talking head** — expected; voiceover suits screen-only
  demos. Use captions for on-camera narration.
- **"Generate Avatar Presenter" is greyed out** — it needs both a saved HeyGen key (test it in
  AI Settings) and a voiceover for the latest recording. Generate the voiceover first.
- **Avatar is cropped or too close** — upload a clear, front-facing photo with some space
  around the head; DemoTape adds headroom, but a tightly-cropped source still frames tight.
- **Avatar render is slow / costs more than expected** — cost and time scale with narration
  length; keep clips short (ideal ~30s). The confirmation dialog shows the estimate first.
- **Menu item missing** — you're on an older build; re-run `./build-app.sh release` and
  relaunch from `/Applications`.
- **Can't paste your key** — fixed in v2 (the app now has a standard Edit menu); make sure
  you're on the latest build.
