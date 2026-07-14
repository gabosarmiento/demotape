# DemoTape — Feature Parity: macOS vs Windows 11

> **Note on the source app.** The task brief called DemoTape an "iOS app." It is not.
> DemoTape is a **native macOS menu-bar app** (AppKit + AVFoundation + Core Image/Metal),
> built as a Swift Package targeting macOS 12.3+. There is no iOS/SwiftUI/UIKit code.
> That is good news for the port: this is a **desktop → desktop** migration, so almost every
> concept has a clean native Windows equivalent.

This document maps every macOS feature, service, and platform integration to its Windows 11
implementation using **C# + .NET 8 + WinUI 3 + Windows App SDK**. Nothing is removed without
asking; where no direct equivalent exists, the closest native Windows alternative is proposed
and flagged **⚠️ NEEDS DECISION**.

---

## 1. Core user flows

| # | macOS flow | Windows 11 flow | Status |
|---|-----------|-----------------|--------|
| 1 | Click menu-bar icon → menu | Click **tray (notification area) icon** → context menu / flyout | Direct |
| 2 | Start Recording (3-2-1 countdown, then capture) | Same: countdown overlay window, then capture | Direct |
| 3 | Global hotkey ⇧⌘S toggles record | Global hotkey **Ctrl+Shift+R** toggles record (configurable) | Adapted (see 10.3) |
| 4 | Record full screen or drag-selected region | Same: full display or drag-to-select region overlay | Direct |
| 5 | Optional mic + webcam PiP overlay | Same | Direct |
| 6 | On Stop → auto-render styled MP4 (hands-off) | Same | Direct |
| 7 | "Web Publish Latest…" → tiered web MP4s + poster + embed.html | Same | Direct |
| 8 | Open recordings folder | Open `%USERPROFILE%\Videos\DemoTape` in Explorer | Direct |

## 2. Screens / navigation

DemoTape has **no main window**; it is a menu-bar accessory (`LSUIElement`) with transient
overlays and small utility windows. Windows has no true "menu-bar app," so the native-idiomatic
equivalent is a **system-tray app** with the same transient windows.

| macOS surface (AppKit) | Windows surface (WinUI 3) | Notes |
|------------------------|---------------------------|-------|
| `NSStatusItem` + `NSMenu` | Tray icon + `MenuFlyout` | Native tray via H.NotifyIcon (open-source) or Win32 `Shell_NotifyIcon` interop |
| `AppDelegate` state machine | `ShellViewModel` (idle/countdown/recording/rendering) | MVVM |
| `CountdownController` overlay | `CountdownWindow` (borderless, topmost, click-through) | `WS_EX_TRANSPARENT` + `WS_EX_LAYERED` |
| `RegionSelector` overlay | `RegionSelectorWindow` (full-screen dim + drag rect) | Same interaction |
| `WebcamSettingsController` overlay | `WebcamSettingsWindow` (live preview circle) | `MediaPlayerElement`/`CaptureElement` |
| `BackgroundPickerController` window | `BackgroundPickerWindow` (thumbnail grid) | `GridView` |
| `WebPublishController` window | `WebPublishWindow` (tier checkboxes + estimate) | **Implemented as the first vertical slice** |
| `NSAlert` dialogs | `ContentDialog` / tray notifications | Direct |

## 3. Data models

Ported **verbatim** as C# records/POCOs in `DemoTape.Domain` — the JSON `.events.json` sidecar
format is preserved 1:1 so recordings are interchangeable and the format is a stable contract.

| Swift (`RecordingMetadata.swift`) | C# (`Domain/Models`) |
|-----------------------------------|----------------------|
| `RecordingMetadata` | `RecordingMetadata` |
| `DisplayInfo` | `DisplayInfo` |
| `CursorSample` | `CursorSample` |
| `ClickSample` | `ClickSample` |
| `ScrollSample` | `ScrollSample` |
| `KeySample` | `KeySample` |

JSON uses camelCase keys and ISO-8601 dates, matching the Swift `JSONEncoder` config.

## 4. Business logic (platform-independent — ported to `DemoTape.Domain`)

| Swift | C# | Testable |
|-------|-----|----------|
| `FocusTimeline` (auto-zoom activity/target/anchor, shortcut badge labels) | `FocusTimeline` | ✅ unit tests |
| Spring camera (critically-damped) inside `VideoRenderer` | `SpringCamera` (extracted) | ✅ unit tests |
| `Transcoder.estimatedBytes`, tier/bitrate tables | `WebPublishPlanner` | ✅ unit tests |
| `WebPublishController.publish` embed/README generation | `WebPublishPlanner.BuildEmbedHtml` / `BuildReadme` | ✅ unit tests |
| Audio normalized-gain math (`normalizedGain`) | `AudioNormalizer.ComputeGain` | ✅ unit tests |
| `Settings` (UserDefaults) | `AppSettings` POCO + `ISettingsStore` | ✅ unit tests |

Keyboard-shortcut **badge glyphs** are re-mapped for Windows conventions:
`⌘`→`Ctrl`, `⌥`→`Alt`, `⇧`→`Shift`, `⌃`→`Ctrl` (macOS control), Return→`Enter`, `⌫`→`Backspace`, etc.

## 5. Local storage

| macOS | Windows |
|-------|---------|
| `~/Movies/DemoTape/` output dir | `%USERPROFILE%\Videos\DemoTape\` |
| `UserDefaults.standard` | `settings.json` in `%LOCALAPPDATA%\DemoTape\` |
| `demotape.log` in output dir | `%LOCALAPPDATA%\DemoTape\logs\demotape-*.log` |
| Bundled `Resources/background/*.png` | App package `Assets/Backgrounds/*.png` |

## 6. Network / API calls

**None.** DemoTape is fully local-first — no telemetry, no accounts, no network code. This is a
core product value and is **preserved exactly** on Windows.

## 7. Permissions

| macOS permission | Windows equivalent | Notes |
|------------------|--------------------|-------|
| Screen Recording (TCC, required) | **None required** | `Windows.Graphics.Capture` shows a system picker/border but needs no persistent grant. Simpler than macOS. |
| Microphone (optional) | Microphone privacy setting | Unpackaged: global toggle; Packaged (MSIX): `microphone` capability |
| Camera (optional) | Camera privacy setting | Same as mic |
| Accessibility (for keystrokes) | **None required** | Low-level keyboard hook works without a grant. ⚠️ We surface a privacy notice since keystrokes are read. |

## 8. Background tasks

| macOS | Windows |
|-------|---------|
| 60 Hz cursor sampler (`DispatchSourceTimer`) | `PeriodicTimer` / multimedia timer on a background thread |
| Concurrent audio/video pump in render | `Task` + `Channel<T>` pipeline |
| Async prepare during countdown | `Task`-based warm-up (async/await) |

## 9. Media / file / device integrations

| macOS (AVFoundation / Core Image) | Windows (native) | Status |
|-----------------------------------|------------------|--------|
| `AVCaptureScreenInput` screen capture | **Windows.Graphics.Capture** (Direct3D frame pool) | Adapted |
| Region crop (`cropRect`) | Crop the captured surface / capture a window | Direct |
| `AVCaptureMovieFileOutput` → .mov | **Media Foundation Sink Writer** / `MediaComposition` → .mp4 | Adapted |
| Webcam via `AVCaptureDevice` | **`MediaCapture`** (Windows.Media.Capture) | Direct |
| Microphone + loudness normalization | `MediaCapture` audio + our `AudioNormalizer` | Direct |
| Core Image/Metal styled render | **Win2D (Direct2D)** compositing pipeline | Adapted |
| `AVAssetReader`/`Writer` transcode | **`MediaTranscoder`** (Windows.Media.Transcoding) | Adapted — used in vertical slice |
| `AVAssetImageGenerator` poster JPEG | `MediaTranscoder`/`MediaClip` frame grab → JPEG | Direct |

## 10. iOS/macOS-specific features → Windows equivalents

1. **Menu-bar accessory (`LSUIElement`)** → Windows tray app. There is no macOS-style global menu
   bar on Windows; a notification-area icon with a context menu is the native convention.
2. **System Preferences deep-links** (`x-apple.systempreferences:`) → `ms-settings:` URIs
   (e.g. `ms-settings:privacy-microphone`).
3. **Global hotkey ⇧⌘S** → `Win+Shift+S` is reserved by the Snipping Tool on Windows, so the default
   becomes **Ctrl+Shift+R** (configurable) via Win32 `RegisterHotKey`. ⚠️ **NEEDS DECISION** on the
   default chord.
4. **Carbon `RegisterEventHotKey`** → Win32 `RegisterHotKey` + a message-only window.
5. **`NSEvent` global monitors** → `SetWindowsHookEx(WH_MOUSE_LL / WH_KEYBOARD_LL)`.
6. **SF Symbols** (menu/tray icons) → **Segoe Fluent Icons** font glyphs.
7. **Self-signed codesign + notarization** → optional **MSIX packaging + code-signing cert**;
   unpackaged builds run without SmartScreen only if signed. ⚠️ **NEEDS DECISION** on packaging.

## 11. Deliberately deferred (nothing removed, only sequenced)

The screen-capture + Win2D styled-render pipeline is large; it is planned but **not** in the first
vertical slice. The first slice is **Web Publish** (transcode an existing styled MP4 to web tiers +
poster + responsive `embed.html`), which exercises every architectural layer end-to-end
(UI → ViewModel → Service → Domain → Infrastructure) and is fully testable.

See `docs/USER-GUIDE.md` for usage and `docs/BUILD.md` for build/run instructions.
