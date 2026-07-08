# AGENTS.md

Guidance for AI coding agents working on **DemoTape**. (Human contributors: see `README.md`.)

## What this is

A native macOS menu-bar screen recorder (Swift + AppKit + AVFoundation + Core Image/Metal)
that auto-styles recordings (auto-zoom, smooth cursor, webcam, framed backgrounds) and
exports lightweight web MP4s. **No external dependencies** — Apple frameworks only. **No
Xcode project** — it's a Swift Package built from the command line.

## Prerequisites

- macOS **12.3+** (Intel or Apple Silicon)
- Xcode **Command Line Tools**: `xcode-select --install`
- Optional: `gh` for release tasks

## Build, run, verify

```bash
# Compile (fast feedback; use this to check your changes build)
swift build -c release

# Run the unit tests (pure logic: caption parsing, SRT/VTT formatting, endpoints)
swift test

# One-time: create the stable self-signed signing identity ("DemoTape Dev").
# Required so macOS remembers Screen Recording permission across rebuilds.
./create-identity.sh

# Package + sign + install to /Applications, then launch
./build-app.sh release
open /Applications/DemoTape.app
```

> Always run the app from **/Applications** (build-app.sh installs it there). macOS grants
> Screen Recording permission unreliably to apps in Desktop/Documents/Downloads.

### Verifying render changes WITHOUT screen-recording permission

The binary has headless hooks so you can test the rendering/encoding pipeline on existing
files (no TCC prompts, no GUI):

```bash
# Re-render a raw recording (.mov + its .events.json sidecar) into a styled .mp4
./.build/release/DemoTape --render "path/to/recording.mov" /tmp/out.mp4

# Transcode a styled .mp4 down to a web tier (height in px)
./.build/release/DemoTape --transcode "path/to/styled.mp4" 540 /tmp/web-540.mp4

# Generate .srt + .vtt captions (opt-in AI, bring-your-own-key). Reads the key from
# the environment so it needs no GUI/Keychain. Requires network + a valid key.
DEMOTAPE_STT_KEY=sk-... ./.build/release/DemoTape --captions "path/to/styled.mp4"
#   Optional: DEMOTAPE_STT_BASEURL (default https://api.openai.com/v1),
#             DEMOTAPE_STT_MODEL (default whisper-1), DEMOTAPE_STT_LANG (e.g. en)
```

Recordings live in `~/Movies/DemoTape/` (`*.mov` raw, `*.events.json` sidecar,
`*.styled.mp4` output, `*.cam.mov` webcam). A run log is at `~/Movies/DemoTape/demotape.log`.

## Hard constraints

- **Target macOS 12.3.** Do not use APIs newer than macOS 13 without an `@available` guard.
  ScreenCaptureKit is intentionally **avoided** — on the target Monterey/Intel hardware its
  `startCapture()` succeeds but delivers zero frames. Capture uses `AVCaptureScreenInput`.
- **No third-party dependencies.** Keep it Apple-frameworks-only and dependency-free.
- **Local by default.** The core recorder/render/publish path must make **no network
  requests**. Network is allowed only in explicitly opt-in, bring-your-own-key AI features
  (e.g. captions in `Captions.swift`), which talk only to the user-configured endpoint with
  the user's key. API keys go in the **Keychain** (`Keychain.swift`), never UserDefaults.
- **Don't commit** recordings, `.app` bundles, `.build/`, or signing artifacts (see `.gitignore`).
- **Never push or create remotes** without the maintainer's explicit request.
- After any change, run `swift build -c release` and `swift test`. For render/encode changes,
  also verify with the `--render` / `--transcode` hooks above; for captions, `--captions`.
- **Add/extend tests** for new pure logic (parsing, formatting, URL building). Keep tests
  network-free — factor the testable logic out of the network call (see `Captions.parseCues`
  / `transcriptionEndpoint`).

## Where things live

See the "Project layout" section in `README.md`. Key files:
`AppDelegate.swift` (menu + orchestration), `RecordingEngine.swift` (capture),
`EventRecorder.swift` (mouse/keyboard timeline), `VideoRenderer.swift` (styled render),
`Transcoder.swift` (web export), `FocusTimeline.swift` (auto-zoom model).
