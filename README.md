<p align="center">
  <img src="Resources/cover-github.jpg" alt="DemoTape" width="100%">
</p>

# DemoTape

A free, open-source, **local-first screen recorder for macOS** that turns raw captures into
polished product demos automatically — auto-zoom on clicks, a smooth cursor, keyboard-shortcut
badges, click ripples, webcam overlay, and framed backgrounds — then publishes them as small,
web-ready MP4s.

It runs on **older Intel Macs and macOS Monterey (12.3+)** — hardware and OS versions many
polished recorders have left behind. No Xcode required to build, no cloud, no account, no telemetry.

## Why

Most tools that turn raw screen captures into polished demos require recent macOS and Apple
Silicon, and they're paid/closed. DemoTape targets the gap: a genuinely useful, free,
hands-off demo recorder that runs on a 2018-era Intel MacBook on Monterey.

## Features

- **Hands-off auto-editing.** Record, and on Stop it renders a styled video automatically —
  no timeline, no keyframing.
- **Spring-physics auto-zoom** that follows your clicks and typing, with **text-input
  tracking** (holds focus on the field while you type instead of zooming out).
- **Synthetic smooth cursor** (the real cursor is hidden during capture and re-drawn cleanly).
- **Keyboard-shortcut badges** (⌘C, ⇧⌘Z…) — shown only for actual shortcuts, not typing.
- **Click ripples** on clicks.
- **Region capture** with a drag-to-select overlay; region recordings are **framed** on a
  gradient background with padding, rounded corners, and a soft shadow.
- **Background gallery** (bundled gradient wallpapers) + custom image picker.
- **Webcam overlay** — a live, draggable, resizable, zoomable circular PiP with a settings
  overlay. Mic + webcam share one capture clock, so lip-sync stays tight.
- **Microphone** capture with automatic loudness normalization.
- **3-2-1 countdown** with the capture warmed up so recording starts instantly at zero.
- **Global hotkey** (⇧⌘S) to start/stop without touching the menu.
- **Web Publish**: transcode to lightweight, fast-loading MP4s (H.264 + AAC, faststart) at
  360/480/540/720p tiers with a live size estimate, plus a poster frame and a responsive
  `<video>` embed snippet.
- **AI captions (opt-in, bring-your-own-key)**: transcribe a recording's audio to `.srt`
  and `.vtt` subtitles via any OpenAI-compatible speech-to-text endpoint (OpenAI, Groq,
  or a local server). Off by default; your key is stored only in the macOS Keychain and
  used only for the request you trigger. See [`docs/captions.md`](docs/captions.md) for
  setup and the list of supported providers.

## Requirements

- macOS **12.3 or later** (Intel or Apple Silicon)
- **Xcode Command Line Tools** (`xcode-select --install`) — full Xcode is **not** required

## Build & run

```bash
# One-time: create a stable self-signed identity so macOS remembers Screen Recording
# permission across rebuilds (otherwise ad-hoc signing resets it every build).
./create-identity.sh

# Build, package, sign, and install to /Applications
./build-app.sh release
open /Applications/DemoTape.app
```

A record icon appears in your menu bar.

> **Run it from `/Applications`, not from a synced/Desktop folder.** macOS grants Screen
> Recording permission unreliably to apps in TCC-protected folders. `build-app.sh` installs
> to `/Applications` for this reason.

### First launch: grant permissions

- **Screen Recording** (required): the first Start shows a prompt → enable DemoTape under
  **System Preferences → Security & Privacy → Privacy → Screen Recording**, then quit and
  reopen. (One-time macOS requirement for any recorder.)
- **Microphone / Camera** (optional): prompted when you enable those features.
- **Accessibility** (optional): needed to capture keystrokes for the shortcut badges.

## Usage

- **⇧⌘S** (or the menu) toggles recording, after a 3-2-1 countdown.
- **Record Full Screen** / **Select Recording Area…** choose the capture mode.
- **Record Microphone**, **Show Webcam**, **Webcam Settings…**, **Background…** toggle and
  configure overlays.
- On Stop, a styled `…styled.mp4` is written next to the raw capture in `~/Movies/DemoTape/`.
- **Web Publish Latest…** exports lightweight web MP4s (one per selected tier) + poster +
  `embed.html` into a `…-web/` folder.
- **AI Features → AI Settings…** enables AI (off by default) and stores your OpenAI-compatible
  API key in the Keychain. **AI Features → Generate Captions for Latest…** then transcribes
  your latest recording into `.srt` + `.vtt` sidecars.

## How it works

- **Capture:** uses the older **`AVCaptureScreenInput`** pipeline rather than ScreenCaptureKit.
  On the target Monterey/Intel machine ScreenCaptureKit's `startCapture()` succeeds but
  delivers **zero frames**, so AVFoundation's proven screen-capture path is used instead
  (works macOS 10.15+). Region capture uses `cropRect`.
- **Event timeline:** cursor is sampled at 60 Hz; clicks, scrolls, and keystrokes are logged
  via `NSEvent` global monitors and saved to a `.events.json` sidecar, normalized to the
  captured region and time-aligned to the video's first frame.
- **Render:** a Core Image / Metal pipeline (`AVAssetReader` → composite → `AVAssetWriter`)
  composes the framed image, then applies a critically-damped **spring camera** to the whole
  composition, and draws the cursor, ripples, webcam, and badges on top. Output is
  web-standard H.264 (High, yuv420p, faststart) + AAC, 30 fps.
- **Web Publish:** transcodes the styled master down to the selected height tiers.

## Project layout

```
Sources/DemoTape/
  main.swift                  App entry + headless --render / --transcode test hooks
  AppDelegate.swift           Menu bar UI, state machine, orchestration
  Settings.swift              UserDefaults-backed preferences
  RecordingEngine.swift       Screen + mic capture (AVCaptureScreenInput), prepare/begin/stop
  CameraRecorder.swift        Separate webcam (+ mic) capture session
  EventRecorder.swift         Cursor/click/scroll/keystroke timeline → .events.json
  RecordingMetadata.swift     Codable model for the sidecar
  FocusTimeline.swift         Auto-zoom camera model (clicks + typing → scale/center)
  VideoRenderer.swift         Core Image/Metal styled render (zoom, cursor, ripples, webcam)
  Transcoder.swift            Web Publish downscale/encode
  CountdownController.swift   3-2-1 overlay
  RegionSelector.swift        Drag-to-select area overlay
  WebcamSettingsController.swift  Live webcam positioning overlay
  BackgroundPicker.swift      Background gallery
  WebPublishController.swift  Web export panel
  GlobalHotKey.swift          Carbon global hotkey (⇧⌘S)
  Log.swift / Paths.swift     Diagnostics + output folder
Resources/
  Info.plist                  Bundle metadata (LSUIElement menu-bar app)
  background/                 Bundled gradient backgrounds
build-app.sh                  Build + package + sign + install to /Applications
create-identity.sh            One-time self-signed signing identity
```

## Security & privacy

- **Local by default.** No telemetry, no analytics, no accounts — recording, styling, and
  Web Publish all stay on your Mac. The only network access is the **opt-in AI captions**
  feature, which uploads a recording's audio to the OpenAI-compatible endpoint *you*
  configure, authenticated with *your* key. Nothing routes through DemoTape's authors, and
  if you never use captions, the app makes no network requests. (All verifiable in the
  source, or with a firewall like Little Snitch.)
- **Writes only to `~/Movies/DemoTape/`,** and only deletes files it created there. It never
  touches your documents or anything outside its own output folder.
- **Unprivileged.** No root, no kernel extensions, no system modification — it can't harm
  macOS; a bug can at most crash the app itself.
- **Permissions it may request** (all handled locally): **Screen Recording** (required),
  **Microphone** / **Camera** (only if you enable audio/webcam), and **Accessibility** (only
  to show keyboard-shortcut badges — keystrokes are logged to a local `.events.json` during
  recording and never transmitted).
- **Not notarized.** Builds are signed with a local self-signed identity, so macOS Gatekeeper
  will warn about an "unidentified developer." Since it's open source, you can read the code
  and build it yourself. `create-identity.sh` adds an untrusted, code-signing-only certificate
  to your login keychain for local signing; it grants nothing and can be removed anytime.

## Known limitations (Monterey)

- **System audio** capture needs a macOS 13+ API. On Monterey, route it through a free
  virtual device (e.g. [BlackHole](https://github.com/ExistentialAudio/BlackHole)).
  **Microphone** works natively.
- **H.264 has no alpha channel** (fine for web/demo use).
- **Distributing to others** requires notarization (an Apple Developer account) or users will
  see Gatekeeper warnings. Building from source works without it.

## Roadmap / ideas

DemoTape today is a local-first *recorder*. The direction we're exploring is an
**AI-friendly demo engine**: record once, then produce a polished, narrated,
multi-format demo — all locally or with your own API keys (BYO key, nothing sent
anywhere you don't control).

**Post-production & voice**
- **Captions**: export audio → transcribe with your choice of engine (local Whisper,
  or OpenAI / Groq speech-to-text) → generate `.srt` / `.vtt` + burned-in captions,
  with an editable transcript.
- **AI voiceover**: turn the edited transcript into a professional voiceover via a
  text-to-speech API (e.g. ElevenLabs) and swap it in for the original track —
  *record silently → generate script → edit → narrate → export.*
- **Multi-language**: one recording → subtitles and voiceovers in several languages.

**Smarter editing**
- **AI Director timeline**: turn the captured event stream (clicks, pauses, shortcuts,
  window/URL/app changes) into *suggested* zooms, cuts of dead time, captions, and
  chapter markers — an editable pass on top of today's auto-zoom.
- **Privacy Shield**: detect and blur likely secrets on screen (API keys, tokens,
  `.env` values, emails, localhost/paths) with a review-before-export mode.
- **Smart silence compression**: trim/speed up loading and dead time while keeping
  cursor motion and audio sync natural.
- **AI cursor cleanup**: smooth shaky paths, snap the cursor near click targets.

**Formats & assets**
- **Vertical / guided camera**: record the desktop, pick a 9:16 mode, and guide the
  crop live (⌥-click "center here") for Reels / Shorts / LinkedIn.
- **Launch-asset generator**: from one recording, produce a README video, animated
  GIF, social clips, poster, and thumbnail.
- **Demo templates**: SaaS launch, open-source project, CLI tutorial, bug report —
  each preset controls aspect ratio, background, captions, zoom style, and export.

**Engine / quality**
- Background render with menu-bar progress for long clips
- Motion blur on fast zoom/cursor transitions
- HEVC variant for even smaller files (with MP4 fallback)
- HLS/fMP4 ladder — only if long-form video is added

Design principle: **local by default, bring-your-own-key for AI.** No mandatory
cloud, no telemetry.

## Contributing

Issues and PRs welcome. Keep it dependency-free (Apple frameworks only) and matching the
existing style. There's no external build system — `swift build` and `./build-app.sh`.

**AI coding agents:** see [`AGENTS.md`](AGENTS.md) for build/run/verify steps and constraints.

## Acknowledgments

Built by studying (not copying) these excellent projects:

- [nonstrict-hq/ScreenCaptureKit-Recording-example](https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example)
  and their [AVCaptureScreenInput guide](https://nonstrict.eu/blog/2023/recording-to-disk-with-avcapturescreeninput/) — the recording-to-disk patterns
- [syi0808/Screenize](https://github.com/syi0808/Screenize) — event-capture and spring-zoom concepts
- [jsattler/BetterCapture](https://github.com/jsattler/BetterCapture),
  [lihaoyun6/QuickRecorder](https://github.com/lihaoyun6/QuickRecorder),
  [danieloquelis/EasyDemo](https://github.com/danieloquelis/EasyDemo) — feature/architecture inspiration
- [keycastr/keycastr](https://github.com/keycastr/keycastr) — keystroke-capture reference

## License

MIT — see [LICENSE](LICENSE).
