# DemoTape for Windows 11

A native **Windows 11** port of [DemoTape](../README.md) — the local-first screen recorder that
auto-styles captures into polished product demos and publishes lightweight web MP4s.

Built with **C# · .NET 8 · WinUI 3 · Windows App SDK**, following Fluent Design, MVVM, and
dependency injection. No cloud, no accounts, no telemetry — everything runs on your PC.

> The upstream app is a **macOS** menu-bar app (AppKit + AVFoundation), not iOS. This is a
> desktop-to-desktop port. See [`docs/FEATURE-PARITY.md`](docs/FEATURE-PARITY.md) for the full
> macOS → Windows mapping.

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
  DemoTape.App.csproj  WinUI 3 tray app (net8.0-windows10.0.19041.0)
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
- ℹ️ The capture/render components require the **Windows SDK** to compile (see `docs/BUILD.md`);
  the portable business logic does not. Custom-effect activation on unpackaged builds falls back
  to saving the raw capture — see the caveat in `docs/BUILD.md`.
- ⏭️ Next: region-crop capture + framed background, webcam PiP, and mic loudness muxing
