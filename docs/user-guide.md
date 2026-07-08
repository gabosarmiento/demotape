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
- Choose **Record Full Screen** or **Select Recording Area…**.
- Toggle **Record Microphone**, **Show Webcam**, **Webcam Settings…**, **Background…**.
- On Stop, a styled `…styled.mp4` is written to `~/Movies/DemoTape/`.

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

## 6. Auto-Cut & Speed Up (local, no AI)

Menu bar → **Auto-Cut & Speed Up Latest…**

- **Remove silent gaps** — scans the audio and cuts pauses longer than ~0.6s (keeping a little
  padding so cuts aren't abrupt), like the jump-cut feature in social video editors.
- **Speed** — 1.1× / 1.25× / 1.5×, with the voice kept natural (pitch preserved).
- **Create** writes a new `…tight.mp4`. Your original is untouched.

This is fully local — no network, no key, no cost. It's the fastest way to make a demo feel
snappy. Tip: run it, then **Web Publish** the result to shrink it for sharing.

## 7. Output files

Everything lands next to the recording in `~/Movies/DemoTape/`:

| File | What it is |
|---|---|
| `…styled.mp4` | The auto-styled recording |
| `…styled.srt` / `.vtt` | Subtitle sidecars (from **Save**) |
| `…transcript.json` | Cached transcript (reused, no re-charge) |
| `…captioned.mp4` | Video with captions burned in (**Add to Video**) |
| `…voiceover.mp4` | Video with the AI narration |
| `…tight.mp4` | Silence-cut / sped-up version (Auto-Cut & Speed Up) |
| `…-web/` | Web Publish output (per-tier MP4s + poster + `embed.html`) |

---

## 8. Costs & privacy

- Captions bill per minute of audio (a 2-minute demo is a fraction of a cent on OpenAI).
  ElevenLabs bills per character of narration. You pay your provider directly.
- Nothing is sent anywhere unless you enable AI and trigger an action, and then only to the
  provider you configured with your key. No telemetry, no accounts. Verifiable in the source
  or with a firewall like Little Snitch.

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
- **Menu item missing** — you're on an older build; re-run `./build-app.sh release` and
  relaunch from `/Applications`.
- **Can't paste your key** — fixed in v2 (the app now has a standard Edit menu); make sure
  you're on the latest build.
