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

## Agent-assisted setup for a tester (run this on the tester's Mac)

This is the recommended way to try DemoTape without a notarized download. Building on the
tester's own machine produces a **native-arch** binary (no Rosetta), signs it with a **stable
local identity** (so Screen Recording permission survives updates), and involves **no
Gatekeeper/quarantine prompt** because nothing is downloaded and run — it's built locally.

**If you are the human tester:** paste the prompt below to your coding agent (Claude Code,
Codex, etc.) from inside a clone of this repo, and let it run the steps.

> Set up and install DemoTape on my Mac by following the "Agent-assisted setup for a tester"
> runbook in AGENTS.md. Run the commands, check each precondition, tell me exactly when you
> need me to click something in System Settings, and stop with a clear message if any step
> fails.

**If you are the agent, run these steps in order and verify each one:**

```bash
# 0. Preconditions ----------------------------------------------------------
sw_vers -productVersion            # must be >= 12.3; abort with a message if lower
uname -m                           # arm64 (Apple Silicon) or x86_64 (Intel) — just informational
xcode-select -p >/dev/null 2>&1 || xcode-select --install   # installs Command Line Tools if missing
#   If it launched the CLT installer, STOP and tell the user to finish the GUI
#   installer, then re-run. Do not proceed until `xcode-select -p` succeeds.

#   IMPORTANT: `xcode-select -p` only proves the *path* is set — it does NOT prove
#   the toolchain is healthy. A partially corrupted Command Line Tools install can
#   pass every check above and still fail the build with the cryptic error
#   `no such module 'PackageDescription'` / `Invalid manifest`. Verify SwiftPM can
#   actually resolve a package manifest before continuing:
swift package --version >/dev/null 2>&1 || {
    echo "SwiftPM is broken (likely a corrupted Command Line Tools install)."
    echo "Fix, then re-run this runbook:"
    echo "  sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
    exit 1
}
#   See the 'no such module PackageDescription' entry under Troubleshooting below.

# 1. Build + verify ---------------------------------------------------------
swift build -c release             # must succeed
swift test                         # 46 tests; all must pass (pure logic, no GUI/network)

# 2. Stable signing identity (one-time; persists Screen Recording permission) --
security find-identity -v -p codesigning | grep -q "DemoTape Dev" || ./create-identity.sh

# 3. Package + sign + install to /Applications ------------------------------
./build-app.sh release             # assembles .app, signs with "DemoTape Dev", installs
open /Applications/DemoTape.app    # a record icon appears in the menu bar
```

**Then hand off to the human for the one-time macOS permission grant (the agent cannot click
these):**

1. Click the DemoTape menu-bar icon and press **Start** once. macOS shows a Screen Recording
   prompt.
2. Open **System Settings → Privacy & Security → Screen Recording**, enable **DemoTape**.
3. **Quit and reopen** DemoTape (required — macOS only applies the grant on relaunch).
4. Microphone / Camera / Accessibility are prompted only if the tester enables those features.

**Notes for the agent:**
- Do **not** use `make-dmg.sh` for a local tester — that path is ad-hoc signed and loses the
  Screen Recording grant on every update. The `build-app.sh` + `create-identity.sh` path above
  keeps the grant stable.
- This flow needs no notarization, no Apple Developer account, and produces a binary matching
  the tester's own CPU architecture.
- To update later, just `git pull` and re-run step 3. The permission persists because the
  signing identity is unchanged.
- If you want to smoke-test the render pipeline without granting Screen Recording, use the
  headless hooks in the next section.

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

# Burn cached captions into a new <name>.captioned.mp4 (no network; uses the
# transcript.json cache or an existing .srt).
./.build/release/DemoTape --burn "path/to/styled.mp4"

# List ElevenLabs voices, and generate a voiceover (BYO ElevenLabs key). Requires network.
DEMOTAPE_ELEVEN_KEY=sk_... ./.build/release/DemoTape --voices
DEMOTAPE_ELEVEN_KEY=sk_... ./.build/release/DemoTape --voiceover "path/to/styled.mp4" script.txt [voiceId]
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

## Troubleshooting

### `no such module 'PackageDescription'` / `Invalid manifest`

`swift build` fails immediately while compiling `Package.swift`, e.g.:

```
error: 'demotape': Invalid manifest
Package.swift:2:8: error: no such module 'PackageDescription'
```

**Cause:** a corrupted or incomplete **Command Line Tools** install. The SwiftPM
manifest API files (`PackageDescription.swiftinterface` / `.swiftmodule`) are missing
from `…/CommandLineTools/usr/lib/swift/pm/ManifestAPI/` even though `swiftc` compiles a
plain file fine and `xcode-select -p` succeeds. Confirm with:

```bash
swift package --version                                            # errors when broken
ls /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI # only the .dylib, no swiftmodule
```

**Fix:** reinstall the Command Line Tools, then finish the GUI installer that appears:

```bash
sudo rm -rf /Library/Developer/CommandLineTools
xcode-select --install
```

If a full Xcode is installed instead, point the toolchain at it:
`sudo xcode-select -s /Applications/Xcode.app`. Re-run the runbook from step 0 afterward.

## Where things live

See the "Project layout" section in `README.md`. Key files:
`AppDelegate.swift` (menu + orchestration), `RecordingEngine.swift` (capture),
`EventRecorder.swift` (mouse/keyboard timeline), `VideoRenderer.swift` (styled render),
`Transcoder.swift` (web export), `FocusTimeline.swift` (auto-zoom model).
