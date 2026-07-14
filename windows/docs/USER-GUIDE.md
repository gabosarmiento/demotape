# DemoTape for Windows — User Guide

DemoTape is a free, **local-first screen recorder for Windows 11** that turns raw screen
captures into polished product demos automatically — auto-zoom on clicks, a smooth cursor,
keyboard-shortcut badges, click ripples, a webcam overlay, and framed backgrounds — then
publishes them as small, web-ready MP4s.

Everything happens on your PC. **No cloud, no account, no telemetry, no network calls.**

---

## Installing / running

See [`BUILD.md`](BUILD.md) for building from source. Once built and running, DemoTape lives in
the **system tray** (notification area, bottom-right of the taskbar). There is no main window —
it works from the tray, like the macOS menu-bar original.

Right-click (or left-click) the DemoTape tray icon to open its menu.

## Tray menu

| Item | What it does |
|------|--------------|
| **Start / Stop Recording** (Ctrl+Shift+R) | Toggles recording after a 3-2-1 countdown |
| **Record Full Screen** | Capture the whole display |
| **Select Recording Area…** | Drag to select a region (recorded with a framed background) |
| **Record Microphone** | Toggle mic capture (with auto loudness normalization) |
| **Show Webcam** | Toggle the circular webcam picture-in-picture |
| **Webcam Settings…** | Position / resize / zoom the webcam circle |
| **Background…** | Choose the framed-mode background (gallery or custom image) |
| **Web Publish Latest…** | Export the latest styled recording to lightweight web MP4s |
| **Open Recordings Folder** | Opens `%USERPROFILE%\Videos\DemoTape` |
| **Quit DemoTape** | Exit |

## Recording

1. Choose **Record Full Screen** or **Select Recording Area…**.
2. (Optional) toggle **Record Microphone** and/or **Show Webcam**.
3. Press **Ctrl+Shift+R** (or the menu). A **3-2-1 countdown** appears, then capture starts.
4. Do your demo — click, type, scroll.
5. Press **Ctrl+Shift+R** again to stop. DemoTape automatically renders a styled
   `…styled.mp4` next to the raw capture. No timeline, no editing.

**Auto-styling applied on Stop:**
- **Spring auto-zoom** that follows your clicks and typing (holds focus on a text field while
  you type instead of zooming out).
- **Smooth synthetic cursor** (the real cursor is hidden during capture and redrawn cleanly).
- **Keyboard-shortcut badges** (e.g. `Ctrl+C`, `Ctrl+Shift+Z`) — only for real shortcuts, not typing.
- **Click ripples** on clicks.
- **Framed background** (region mode): padding, rounded corners, soft shadow over a gradient/image.
- **Webcam PiP** and **normalized mic audio**, kept in lip-sync.

## Web Publish (implemented vertical slice)

**Web Publish Latest…** turns your newest `…styled.mp4` into small, fast-loading web videos.

1. Pick one or more **quality tiers**: 360p / 480p / 540p / 720p.
2. Watch the **live total-size estimate** update as you toggle tiers.
3. Click **Export**. DemoTape writes a `…-web\` folder next to the recording containing:
   - `demo-<tier>p.mp4` — H.264 + AAC, faststart, per selected tier
   - `poster.jpg` — a first-frame thumbnail
   - `embed.html` — a responsive `<video>` snippet that serves the right size per screen
   - `README.txt` — what each file is and how to use it

**Tip:** use 720p only when the demo has small UI text or code. Uploading to X/LinkedIn?
Upload the largest MP4 directly — they re-encode it. Hosting on your own site? Upload all files
and use `embed.html`.

## Where files go

```
%USERPROFILE%\Videos\DemoTape\
  DemoTape 2026-07-08 at 14.30.00.mp4          raw capture
  DemoTape 2026-07-08 at 14.30.00.events.json  event timeline sidecar
  DemoTape 2026-07-08 at 14.30.00.styled.mp4   auto-styled output
  DemoTape 2026-07-08 at 14.30.00.cam.mp4       webcam (if enabled)
  DemoTape 2026-07-08 at 14.30.00-web\          web-published tiers
%LOCALAPPDATA%\DemoTape\
  settings.json                                 preferences
  logs\demotape-*.log                           run log
```

## Permissions & privacy

- **Screen capture**: Windows requires **no persistent permission** — capture just works
  (Windows may briefly show a capture border). Simpler than macOS.
- **Microphone / Camera**: only used if you enable them. If capture fails, check
  **Settings → Privacy & security → Microphone / Camera** (deep-links provided in-app).
- **Keystrokes**: captured **only during recording** to draw shortcut badges, saved to a local
  `.events.json`, and **never transmitted**. You can turn shortcut badges off.
- **Local-only**: no telemetry, no accounts, no network. Verifiable in the source.

## Keyboard shortcut

- **Ctrl+Shift+R** — start/stop recording (configurable). `Win+Shift+S` is avoided because
  Windows reserves it for the Snipping Tool.
