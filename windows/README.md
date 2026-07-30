# DemoTape for Windows 11

A native **Windows 11** port of [DemoTape](../README.md) — the local-first screen recorder that
auto-styles captures into polished product demos and publishes lightweight web MP4s.

Built with **C# · .NET 8 · WinUI 3 · Windows App SDK**, following Fluent Design, MVVM, and
dependency injection. No cloud, no accounts, no telemetry — everything runs on your PC.

> The upstream app is a **macOS** menu-bar app (AppKit + AVFoundation), not iOS. This is a
> desktop-to-desktop port. See [`docs/FEATURE-PARITY.md`](docs/FEATURE-PARITY.md) for the full
> macOS → Windows mapping.

## Try it (build it yourself)

DemoTape for Windows is **not code-signed**, so a downloaded prebuilt `.exe` would trip Windows
SmartScreen ("unknown publisher"). A code-signing certificate is a paid, per-year thing and isn't a
priority for a local tool — so the recommended way to try it is to **build it on your own machine**.
Building locally produces a native-arch binary, needs no signing, and triggers **no SmartScreen
prompt** (nothing is downloaded and run).

The easiest path is to let your coding agent (Kiro, Claude Code, etc.) run the setup for you — from
a clone of this repo, ask it to run the runbook:

```powershell
# From the repo root, in PowerShell (see docs/BUILD.md for details):
windows\setup.ps1
```

It checks prerequisites (.NET 8 SDK; it will tell you if the Windows 11 SDK is missing), runs the
unit tests, publishes a self-contained app to `windows\dist\DemoTape`, and adds Desktop + Start Menu
shortcuts. To update later: `git pull`, then re-run it. There's no account, no cloud, no telemetry —
everything runs on your PC.

## Documentation

- [`docs/FEATURE-PARITY.md`](docs/FEATURE-PARITY.md) — every macOS feature mapped to Windows
- [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md) — end-user guide
- [`docs/BUILD.md`](docs/BUILD.md) — build & run instructions

## Quick start

```powershell
cd windows

# Business logic: builds & tests with only the .NET 8 SDK
dotnet test tests/DemoTape.Tests/DemoTape.Tests.csproj -c Release

# Full app (needs the Windows App SDK / Windows SDK — see docs/BUILD.md)
dotnet run --project src/App/DemoTape.App.csproj -c Release
```

## Architecture

```
src/App/
  Domain/            DemoTape.Domain (net8.0)      models · FocusTimeline · SpringCamera
                                                   WebPublishPlanner · AudioNormalizer · interfaces
  Services/          DemoTape.Services (net8.0)    WebPublishService (orchestration)
  ViewModels/        DemoTape.ViewModels (net8.0)  ShellViewModel · WebPublishViewModel (MVVM)
  Infrastructure/    (in DemoTape.App)             Windows impls: transcoder, stores, hotkey, logging
  UI/                (in DemoTape.App)             WinUI 3 windows + navigation
  DemoTape.App.csproj  WinUI 3 tray app (net8.0-windows10.0.22621.0)
tests/
  DemoTape.Tests/    xUnit — Domain + Services + ViewModels
```

The **Domain**, **Services**, and **ViewModels** layers are pure `net8.0` with no WinUI
dependency, so the business logic is fully unit-testable on any machine with the .NET SDK. Only
the thin **App** shell (UI + Infrastructure) needs the Windows App SDK toolchain.

## Status

- ✅ Feature-parity + user + build docs
- ✅ Clean MVVM + DI scaffold; **59 unit tests** green (Domain + Services + ViewModels)
- ✅ Vertical slice 1: **Web Publish** end-to-end (UI → ViewModel → Service → Domain → Media Foundation)
- ✅ Vertical slice 2: **capture + auto-styled render** — `Windows.Graphics.Capture` recording,
  Win32 event timeline, 3-2-1 countdown, Win2D auto-zoom/cursor/ripple/badge effect, and the
  tray-driven `WindowsRecordingController` state machine
- ✅ Ported + unit-tested business logic: focus timeline, spring camera, render geometry,
  publish planning, audio normalization, input mapping
- ✅ **Region-crop capture + framed background** (drag-to-select overlay + background gallery)
- ✅ **Webcam PiP** (circular overlay) with a **live Webcam Settings** positioner (CommunityToolkit CameraPreview)
- ✅ **Microphone** capture muxed into the styled output
- ✅ Sequential frame-server render (~real-time) with in-tray progress
- ℹ️ The capture/render/preview components require the **Windows SDK** to compile (see `docs/BUILD.md`);
  the portable business logic (Domain/Services/ViewModels) does not.
- ⏭️ Possible next steps: MSIX packaging + code signing, system-audio capture, render-progress bar
