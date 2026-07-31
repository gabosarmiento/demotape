# Changelog

All notable changes to DemoTape are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file was generated from the project's GitHub Release notes; the
[Releases page](https://github.com/gabosarmiento/demotape/releases) remains the
source for downloadable DMGs and checksums. All versions target macOS 12.3+
(Intel and Apple Silicon).

## [Unreleased]

<!--
  Maintainers: add notable user-facing changes here under Added / Changed /
  Fixed / Removed as they land, then move them under a new version heading at
  release time (and add its compare link at the bottom). PR authors: if your
  change is user-visible, add a line here — see CONTRIBUTING.md.
-->

## [7.5.1] - 2026-07-31

### Fixed

- Captions no longer clip in portrait/square exports — caption blocks now shrink
  to fit frame width, so a 4:5 / 9:16 reframe no longer runs centered text off both edges.
- `--tighten` no longer removes pauses when you only asked to speed up. New named
  form `--tighten <video> --speed 1.25` changes only speed; silence removal is
  opt-in via `--remove-silence`. The old positional form is unchanged.
- Narration is now cached across every path, keyed by (voice, text). `revoice`
  and `narrate` accept `--video <path>` to target a specific cut.

### Notes

- The Windows port has the same caption-fit bug and is not addressed here.

## [7.5.0] - 2026-07-30

### Changed

- Web Export (renamed from "Web Publish") rebuilt with live per-tier progress, a
  non-blocking background encode that finishes even if you close the window, and
  a carousel of the recording folder's videos (thumbnail, newest first, reveal in Finder).
- Renamed Auto-Cut to "Speed up / Auto-cut" and moved it directly above Add Captions.
- README repositioned around the core: making a demo fast with your coding agent,
  for developers and vibecoders. Verified demos are now one use case, not the headline.

### Removed

- Auto-Edit — it didn't deliver a result worth shipping.

## [7.4.0] - 2026-07-30

Supersedes v7.3.0, which was tagged but never shipped a binary.

### Added

- `--reframe` — turn any landscape recording into a 9:16, 1:1 or 4:5 cut with a
  planned camera (not a crop): fills height and crops sides, holds on shots,
  follows typed text, routes long moves through an overview zoom-out, and clamps
  the sampled rect to the source every frame. `--debug` draws the camera rect.
  Recipe fields: `reframeTarget`, `reframeZoom`, `reframeDebug`.
- `scripts/local-ai.sh` — one command sets up local speech models (Kokoro for
  narration, Whisper for captions) bound to `127.0.0.1`, points DemoTape at them,
  and proves it works end to end. No key written, Keychain untouched. Flags:
  `--status`, `--stop`, `--uninstall`, `--tts-only`, `--stt-only`.
- `--encode-frames` — turns a captured frame sequence into a raw `.mov` the rest
  of the pipeline treats as an ordinary recording, so styled render, auto-zoom,
  captions, voiceover and reframe all work without Screen Recording permission.

### Fixed

- Typing now stays in frame in `contenteditable` chat composers and rich editors
  (the caret was previously measured from `el.value`, which doesn't exist there).
- Capture mode buttons are legible — icon above the label instead of a truncated
  segmented control.
- A blinking red tally light appears beside the timer while recording (respects
  Reduce Motion).
- `install.sh --kiro` is now idempotent (a second run no longer nests a duplicate
  copy of every reference guide).

## [7.2.0] - 2026-07-29

### Added

- App-wide, VHS-inspired theme that follows the system Light/Dark setting: a
  "tape shell" palette with the six-color logo stripe as the brand signature and
  a purple accent for interactive controls (red stays reserved for Record).
  Themed across the control bar, popover, welcome screen, action windows and settings dialogs.

### Notes

- Signed + notarized universal build. No changes to recording, the demo driver,
  or the CLI.

## [7.1.0] - 2026-07-29

### Added

- Finer speed controls in the Teleprompter and Auto-Cut: a slider snapping to
  0.1× over a "recommended" band, with live readout and −/+ steppers.
- Teleprompter: a "Copy AI script prompt" button, a taller reading window with
  soft fades, and a larger reserved (unrecorded) strip.
- Optimize for social media (opt-in): pick a platform and DemoTape exports in the
  right shape.
- First-run explainer cards for Output formats, Teleprompter, Share Recording for
  AI, and the coding-agent composer, each with "Don't show again".

### Fixed

- A recording crash on macOS 12 from the cursor-shape Accessibility probe
  hit-testing an open menu.
- Auto-Cut and Teleprompter windows sometimes failing to appear.
- Clicking the Dock icon now always brings back the recorder bar.
- Switching Select Area ↔ Webcam Only no longer needs a Full-Screen detour.
- Caption style previews adapt to the video's aspect.

## [7.0.0] - 2026-07-27

### Added

- Webcam Only capture mode: a first-class mode alongside Full Screen and Select
  Area, recording just the camera at 1080p with a near-full-screen live stage,
  Mirror camera toggle, teleprompter support, and Enhance audio / Noise
  suppression toggles.
- Recorder bar: a third Webcam Only segment in the ••• selector, Lock area
  position (click/scroll/type in the app beneath a framed area), click-through
  region interior with a "Drag to move" pill, and inline Teleprompter settings.

### Fixed

- Clicking the Dock icon reopens the recorder bar.
- AI Settings no longer triggers a password-AutoFill overlay over the Test button.
- Sweeps orphaned atomic-write temp files (`*.sb-*`) after an interrupted export.
- Caption reliability: dropped-word reconciliation, word-timing normalization,
  and a fix for the caption-burn memory spike.

## [6.6.0] - 2026-07-27

### Added

- The coding-agent path is now a co-equal primary action — first in the menu as
  "Let Your Coding Agent Record a Demo…" — with a bundled skill that reads a
  codebase, scripts scenes, drives the app, records with synced voiceover, and
  verifies each scene. Localization built in (another language or subtitles from
  the same footage).
- A ••• settings popover on the recorder bar for capture mode, the agent path,
  and pre-take choices (background, branding, teleprompter, auto-zoom).
- Agent marks (Cursor, Claude Code, Copilot, Gemini, Codex) drawn natively from
  vector paths (macOS 12 can't load SVG and the app ships no dependencies).

### Changed

- Captions reworked: word-by-word social styles (One Word, Word Pair) plus Mono
  for engineering demos, a Design-led layout, real progress percentage, and a
  consistent "Copy prompt for your agent" hand-off.

### Fixed

- Words no longer drop from captions (Whisper's zero-duration and omitted
  trailing words are reconciled and given readable, non-overlapping slots).
- Caption burn no longer exhausts memory — long clips render in seconds at flat memory.
- Transcripts cached per timeline, so a sped-up or re-voiced clip never shows the
  original's cue times.
- Windows that could push their action button off screen now fit; voiceover/caption
  window crashes gone.

## [6.5.0] - 2026-07-26

### Added

- Add another language to a finished demo as a new file on the same timings, with
  the original left playable; per-line fit measurement flags overruns, with a
  per-line cache.
- Two word-by-word caption styles (One Word, Word Pair) plus Mono; `--burn … --srt`
  burns a specific subtitle file instead of silently ignoring it.
- Both Captions and Voiceover windows can hand the job to a coding agent; the
  bundled skill carries those instructions.

### Changed

- The pointer is drawn as the shape the system was showing (hand over a link,
  text bar over a field); attention gestures aim at the words inside a target.
- Vision verification paces itself against the token budget, keeps the spec beside
  the video for re-runs, and treats an on-screen refusal as a legitimate result.
  `--frame` writes stills.

### Fixed

- Driver scenes run their steps in order, so `wait` waits.
- The action button can no longer fall off the bottom of a window.

## [6.4.0] - 2026-07-25

### Added

- `--publish` runs the full Web Publish pipeline headlessly (same code path as
  the GUI), previously locked inside the GUI controller.
- Coordinate-free UI targeting for scripted demos: resolve a control by label
  against the live UI (AppKit for own windows, Accessibility API for other apps)
  and click it — `demotape://ui/click?label=Export`, plus `ui/find`, `ui/dump`,
  `ui/open`, and `cursor/glide`. A miss is reported, not guessed.
- A star ask in About, the Welcome screen, and the menu bar.

### Fixed

- Camera toggle is honest — turning the webcam on requests Camera access and
  stays off if denied (reconciled at launch).
- One permission prompt, not three — screen-capture status is checked on window
  activation instead of on a timer.
- Install instructions corrected: the DMG is signed and notarized, so it just opens.

## [6.3.1] - 2026-07-25

### Fixed

- Camera/webcam toggle is honest — requests Camera access, stays off if denied.
- Consistent signing: `build-app.sh` now signs with Developer ID + hardened
  runtime + entitlements, matching the notarized DMG, so permission grants persist
  across updates.

### Changed

- Value-forward permission copy and a single Settings redirect.
- Welcome appears whenever Screen Recording is missing; About refreshes permission
  status live.
- "Create a Demo with AI" redesigned skill-first with a "Works with" agent row.

## [6.3.0] - 2026-07-24

DemoTape is now **free and open source (MIT)**.

### Removed

- The license gate entirely — the app launches straight into the menu bar.
- The licensing code (License/Signer/Controller), the `--license-keygen` /
  `--gen-license` CLI hooks, and the Keychain license account.

### Notes

- `swift build -c release` and `swift test` green (187 tests).

## [5.7.0] - 2026-07-14

### Added

- Per-recording folders — one clean folder per recording, with shareable outputs
  (the styled video and `-web` bundle) at the root and raw captures/sidecars in a
  hidden `.source/` subfolder.
- "Reveal Latest Export" menu item (Recording Folder → Reveal Latest Export).
- Automatic migration of existing recordings into the new structure (moves only,
  never deletes; skips anything already in place).

## [5.6.0] - 2026-07-14

### Added

- New 5:4 preset and a Social media row of recording-area presets (YouTube,
  Shorts, TikTok, Instagram Reel/Story/Post, LinkedIn vertical & square, Facebook
  Video/Post), each sized for its destination; the frame smoothly expands into
  place with proportions locked.
- Live camera bubble inside the recording area, exactly where it lands in the
  final video (disappears when recording starts).

### Changed

- Captions sit bottom-center in short, readable chunks on regular videos; mobile
  aspects keep the centered look.
- Smart Noise Suppression reworked to run much lighter on memory and clean steady
  noise more aggressively, with a high-pass for low rumble.

## [5.5.0] - 2026-07-14

### Added

- Animated, styled captions with eight looks in a new Design tab: four animated
  (Pop, Karaoke, Highlight, Pop Green) driven by word-level timing, and four
  static (Clean, Bold, Minimal, Boxed).
- Mobile-aware line tightening (1–2 words per line) for 1:1, 4:5 and 9:16.
- `--burn` accepts an optional style id.

### Notes

- 107 tests pass.

## [5.4.0] - 2026-07-14

### Changed

- Auto-Edit rebuilt into an AI director that composes a shot list from the screen
  and camera feeds — full-screen while working, you full/close-up for intros,
  clean split-screen two-shots, and broadcast-style push-ins and pans. Three
  modes: Smart · Local (clicks and pauses, no network), Smart · AI (reads
  narration + activity with your own key; only transcript and timing are sent),
  and Genres (Clean, Keynote, Social, Commercial, Vlog).

## [5.3.0] - 2026-07-13

### Added

- Auto-Edit unified under After Recording → Auto-Edit Latest… with a Style picker.
- Smart · reads your clicks & pauses (Local) — an auto director that cuts between
  screen and webcam with natural rhythm, never mid-click, with a gentle presenter
  drift. Builds on the existing click-follow zoom. Fully on-device.

### Notes

- Smart · AI marked coming soon.

## [5.2.0] - 2026-07-13

### Added

- Input → Enhance Voice toggle — a warmer, more consistent "studio condenser"
  sound (gentle EQ plus compression) applied during render. One preset, fully
  on-device.

## [5.1.0] - 2026-07-13

### Added

- Input → Smart Noise Suppression toggle — cleans steady background noise (fans,
  hum, hiss, room tone) at a fixed level during render. Fully on-device (Apple's
  Accelerate framework), best on steady noise.

## [5.0.0] - 2026-07-13

### Added

- Focused action windows — every post-recording action is its own window with the
  working file and a Change… button, Source/Result players, controls, one
  Generate preview, and the finished file as a link with Reveal in Finder.
  Covers Auto Cut and Speed, Captions, Voiceover (with one-click voice audition),
  Avatar Presenter (from a photo or library, 720p, with a cost estimate), and
  Apply Template.

### Changed

- Web Publish keeps its lightweight multi-tier export (embed, poster, GIF).

### Fixed

- Removed a jitter effect in Apply Template that could make edits feel buggy.

## [4.0.0] - 2026-07-11

### Added

- Auto-edit templates — after recording, pick a template and DemoTape re-edits the
  latest recording into a richer video (zoom, punch, flip, slide, speed ramp,
  blur, shake, drift, angle switches, fades) with a blurred zoomed-fill backdrop.
  Eight looks: Clean, Social, Sports Broadcast, Race Broadcast, Reality Show,
  Commercial, Keynote, Vlog. Menu → After Recording → Apply Template to Latest…
- System Preferences submenu (Launch at Login, Show in Dock, Enable Auto-Zoom).
- First-run Welcome showing only the permissions still needed.
- About DemoTape with version + live permission status, Check for Updates, Report
  an Issue.
- Redesigned AI Settings: secure key entry (Keychain), independent Captions and
  Voiceover toggles, and a Test-key button.

## [3.1.0] - 2026-07-10

### Added

- Recording-area presets from the region-selection screen (Freeform, 4:5, 1:1,
  16:9, 9:16) with aspect ratio locked while dragging and the final video scaled
  to the target size.
- One-click GIF export from Web Publish (native, no ffmpeg): Smaller / Balanced /
  Sharp, capped at 30s, looping, written as `demo.gif` in the `-web/` folder.
- Render notifications — a start heads-up and a "ready 🎬" notification with a
  Reveal in Finder action (permission requested once; falls back to the
  reveal-in-Finder prompt if off).

## [3.0.0] - 2026-07-09

### Added

- Recorder HUD — a floating, draggable control bar (Start/Stop, live timer, mic +
  webcam toggles, cancel) with tooltips, hover cursors and keyboard support; the
  selected area stays on screen as an adjustable, move/resize frame that isn't captured.
- Teleprompter — paste a script that scrolls while recording but stays out of the
  capture (a cropped edge strip in full-screen, the margin in Select Area), with
  Script and Display settings tabs.
- Branding — upload, drag, resize and confirm a logo to watermark exports.
- A proper app icon and a branded menu-bar icon with state glyphs.
- Reorganized menu into Input / Background / Branding / Teleprompter submenus, an
  After Recording section, and a Recording Folder submenu with a persisted output directory.

## [2.1.0] - 2026-07-08

### Added

- Auto-Cut & Speed Up Latest… — remove silent gaps (loudness analysis trims
  pauses longer than ~0.6s, jump-cut style, with padding) and optionally speed up
  (1.1× / 1.25× / 1.5×, pitch preserved). Outputs a new `…tight.mp4`; original
  untouched. Fully local, no API key. Headless hook: `--tighten <video> [speed]
  [removeSilence 0|1]`.

## [2.0.0] - 2026-07-08

### Added

- AI captions — transcribe via any OpenAI-compatible endpoint, review/edit the
  lines, then save `.srt` / `.vtt` sidecars or burn them in (`…captioned.mp4`).
  Transcripts cached (`…transcript.json`) so re-opening never re-charges.
- AI voiceover — write, pre-fill from the transcript, or load a `.txt` script;
  pick an ElevenLabs voice; lay narration over the video (`…voiceover.mp4`).
- AI Settings panel (enable AI, provider preset OpenAI/Groq/Custom, store STT +
  ElevenLabs keys in the Keychain).
- Edit menu (Cut/Copy/Paste/Select All) in the app's windows.
- Headless hooks `--captions`, `--burn`, `--voices`, `--voiceover`, and a unit
  test suite (`swift test`).
- Docs: a full User Guide and a captions/provider reference.

### Notes

- The AI layer is opt-in and off by default; with it off, DemoTape makes no
  network requests.

## [1.0.0] - 2026-07-08

First public release of DemoTape — a free, open-source macOS screen recorder that
turns raw captures into polished demos automatically. Builds and runs on older
Intel Macs and macOS Monterey (12.3+), no Xcode required.

### Added

- Hands-off auto-editing — on Stop it renders a styled video automatically (no timeline).
- Spring-physics auto-zoom that follows clicks and typing, with text-input tracking.
- Synthetic smooth cursor, keyboard-shortcut badges, and click ripples.
- Full-screen or drag-to-select region capture; region recordings framed on
  gradient backgrounds with padding, rounded corners and shadow (with a background
  gallery + custom image).
- Webcam overlay — live draggable/resizable/zoomable circular PiP; mic + webcam
  share one clock for tight lip-sync.
- Microphone capture with automatic loudness normalization.
- 3-2-1 countdown and a global start/stop hotkey.
- Web Publish — lightweight MP4s (H.264 + AAC, faststart) at 360/480/540/720p
  tiers, plus a poster and a responsive embed snippet.

[Unreleased]: https://github.com/gabosarmiento/demotape/compare/v7.5.1...HEAD
[7.5.1]: https://github.com/gabosarmiento/demotape/compare/v7.5.0...v7.5.1
[7.5.0]: https://github.com/gabosarmiento/demotape/compare/v7.4.0...v7.5.0
[7.4.0]: https://github.com/gabosarmiento/demotape/compare/v7.2.0...v7.4.0
[7.2.0]: https://github.com/gabosarmiento/demotape/compare/v7.1.0...v7.2.0
[7.1.0]: https://github.com/gabosarmiento/demotape/compare/v7.0.0...v7.1.0
[7.0.0]: https://github.com/gabosarmiento/demotape/compare/v6.6.0...v7.0.0
[6.6.0]: https://github.com/gabosarmiento/demotape/compare/v6.5.0...v6.6.0
[6.5.0]: https://github.com/gabosarmiento/demotape/compare/v6.4.0...v6.5.0
[6.4.0]: https://github.com/gabosarmiento/demotape/compare/v6.3.1...v6.4.0
[6.3.1]: https://github.com/gabosarmiento/demotape/compare/v6.3.0...v6.3.1
[6.3.0]: https://github.com/gabosarmiento/demotape/compare/v5.7.0...v6.3.0
[5.7.0]: https://github.com/gabosarmiento/demotape/compare/v5.6.0...v5.7.0
[5.6.0]: https://github.com/gabosarmiento/demotape/compare/v5.5.0...v5.6.0
[5.5.0]: https://github.com/gabosarmiento/demotape/compare/v5.4.0...v5.5.0
[5.4.0]: https://github.com/gabosarmiento/demotape/compare/v5.3.0...v5.4.0
[5.3.0]: https://github.com/gabosarmiento/demotape/compare/v5.2.0...v5.3.0
[5.2.0]: https://github.com/gabosarmiento/demotape/compare/v5.1.0...v5.2.0
[5.1.0]: https://github.com/gabosarmiento/demotape/compare/v5.0.0...v5.1.0
[5.0.0]: https://github.com/gabosarmiento/demotape/compare/v4.0.0...v5.0.0
[4.0.0]: https://github.com/gabosarmiento/demotape/compare/v3.1.0...v4.0.0
[3.1.0]: https://github.com/gabosarmiento/demotape/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/gabosarmiento/demotape/compare/v2.1.0...v3.0.0
[2.1.0]: https://github.com/gabosarmiento/demotape/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/gabosarmiento/demotape/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/gabosarmiento/demotape/releases/tag/v1.0.0
