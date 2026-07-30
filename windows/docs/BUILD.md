# Building & running DemoTape for Windows

## Agent-assisted setup for a tester (one command)

The fastest way to install DemoTape on a tester's own Windows 11 machine — the Windows counterpart
of the macOS "Agent-assisted setup for a tester" runbook in [`../../AGENTS.md`](../../AGENTS.md).
It builds a **native-arch, self-contained** app (no runtime install), drops Desktop + Start Menu
shortcuts, and can register it to open at login. Because nothing is downloaded and run, there's no
SmartScreen/quarantine prompt; and Windows screen capture needs **no persistent permission grant**,
so recording works right after install.

**If you are the human tester**, paste this to your coding agent from inside a clone of the repo:

> Set up and install DemoTape on my Windows machine by running `windows\setup.ps1`. Check each
> precondition, tell me exactly when a manual step is needed (e.g. installing the Windows SDK), and
> stop with a clear message if any step fails.

**If you are the agent**, run:

```powershell
# From the repo root, in PowerShell:
windows\setup.ps1                 # build + test + publish + shortcuts + launch
windows\setup.ps1 -Startup        # also open DemoTape at login
windows\setup.ps1 -NoLaunch       # install without launching
```

The script verifies the .NET 8 SDK, runs the unit-test gate, publishes to `windows\dist\DemoTape\`,
and creates the shortcuts. If the WinUI app can't build because the **Windows 11 SDK** / Windows App
SDK tooling is missing (an elevated GUI install an agent can't click), it stops with the exact
install commands — see the prerequisites below — then you re-run it.

To update later: `git pull`, then re-run the script.

## What builds where

The Windows port is split so that **all business logic builds and tests with only the .NET SDK**,
while the WinUI 3 desktop shell requires the Windows App SDK tooling.

| Project | Target | Needs |
|---------|--------|-------|
| `src/App/Domain/DemoTape.Domain.csproj` | `net8.0` | .NET 8 SDK only |
| `src/App/ViewModels/DemoTape.ViewModels.csproj` | `net8.0` | .NET 8 SDK only |
| `tests/DemoTape.Tests/DemoTape.Tests.csproj` | `net8.0` | .NET 8 SDK only |
| `src/App/DemoTape.App.csproj` | `net8.0-windows10.0.22621.0` (WinUI 3) | .NET 8 SDK + **Windows SDK** + Windows App SDK |

## Prerequisites

- **.NET 8 SDK** — `winget install Microsoft.DotNet.SDK.8`
- For the **WinUI 3 app** additionally, the **Windows 11 SDK (10.0.22621+)**, which provides the
  XAML→XBF compiler (`genxbf.dll`) and reference packs. Install it one of these ways:
  - **Visual Studio 2022** (17.8+) with the **".NET Desktop Development"** workload and the
    **"Windows 11 SDK (10.0.26100)"** + **"Windows App SDK C# Templates"** components (recommended), **or**
  - The **standalone Windows SDK installer** (run elevated — it needs admin):

    ```powershell
    # Download once, then install the SDK feature silently (approve the UAC prompt)
    Invoke-WebRequest "https://go.microsoft.com/fwlink/?linkid=2196241" -OutFile "$env:TEMP\winsdksetup.exe"
    Start-Process "$env:TEMP\winsdksetup.exe" -ArgumentList '/features','OptionId.WindowsSoftwareDevelopmentKit','/quiet','/norestart' -Verb RunAs -Wait
    ```

  The `Microsoft.WindowsAppSDK`, `Microsoft.Windows.SDK.BuildTools`, and `Microsoft.Graphics.Win2D`
  NuGet packages are restored automatically by the csproj.

> The `Domain`, `ViewModels`, `Services`, and `Tests` projects build and test with **only the .NET
> SDK** — no Windows SDK required. Only the `DemoTape.App` shell needs the Windows SDK.

## Build & test the business logic (no Windows App SDK required)

```powershell
cd windows

# Restore + build the pure-.NET projects and run the unit tests
dotnet test tests/DemoTape.Tests/DemoTape.Tests.csproj -c Release
```

This compiles `DemoTape.Domain` + `DemoTape.ViewModels` and runs the xUnit suite covering the
auto-zoom focus timeline, spring camera, web-publish planning, audio normalization, and settings.

## Build & run the full WinUI 3 app
hello
```powershell
cd windows

# Restore + build everything, including the WinUI 3 shell
dotnet build DemoTape.sln -c Release

# Run the desktop app (or press F5 in Visual Studio)
dotnet run --project src/App/DemoTape.App.csproj -c Release
```

> If `dotnet build DemoTape.sln` fails on the `DemoTape.App` project with a missing Windows SDK
> or Windows App SDK error, install the prerequisites above. The `Domain`, `ViewModels`, and
> `Tests` projects will still build and test on a machine with only the .NET SDK.

On launch, a DemoTape icon appears in the **system tray**. There is no main window (it mirrors the
macOS menu-bar design).

## Project layout

```
windows/
  DemoTape.sln
  Directory.Build.props            Shared build settings (nullable, langversion, analyzers)
  docs/
    FEATURE-PARITY.md              macOS → Windows mapping
    USER-GUIDE.md                  End-user documentation
    BUILD.md                       This file
  src/App/
    Domain/                        DemoTape.Domain (net8.0) — models + business logic + interfaces
    ViewModels/                    DemoTape.ViewModels (net8.0) — MVVM, testable
    UI/                            WinUI 3 Views/Pages/Windows (XAML)
    Services/                      Application services (orchestration)
    Infrastructure/                Windows-native implementations (capture, transcode, storage, hooks)
    DemoTape.App.csproj            WinUI 3 desktop app (net8.0-windows...)
  tests/
    DemoTape.Tests/                xUnit tests for Domain + ViewModels
```

## Verifying render/encode without a GUI (parity with the macOS `--render`/`--transcode` hooks)

The Windows app exposes the same headless hooks for testing the pipeline on existing files:

```powershell
# Transcode a styled mp4 down to a web tier (height in px)
dotnet run --project src/App/DemoTape.App.csproj -- --transcode "C:\path\styled.mp4" 540 "C:\tmp\web-540.mp4"

# Web-publish a styled mp4 to a folder of tiers + poster + embed.html
dotnet run --project src/App/DemoTape.App.csproj -- --publish "C:\path\styled.mp4" 360,540,720

# Encode a captured frame sequence (JPEGs + manifest.json) into a raw mp4, then style it.
# This is the "no screen-capture permission" path: the demo-driver captures the page over the
# DevTools protocol and writes the frames + events sidecar, DemoTape just encodes + renders.
dotnet run --project src/App/DemoTape.App.csproj -- --encode-frames "C:\caps\manifest.json" "C:\caps\capture.mov"
dotnet run --project src/App/DemoTape.App.csproj -- --render "C:\caps\capture.mov" "C:\caps\capture.styled.mp4"
```

## Agentic control surface (`demotape://`) — drive a hands-off demo

Parity with the macOS control surface: a **running** DemoTape registers the `demotape://` URL scheme
and publishes its state to a pollable status file, so an external orchestrator (e.g. the Playwright
[`tools/demo-driver`](../../tools/demo-driver/)) can record a demo end-to-end without touching the UI:
**start a screen rectangle → drive the app → stop → collect the finished video.**

- `demotape://record/start?countdown=0` — full screen, begin immediately.
- `demotape://record/start?mode=area&x=&y=&w=&h=&countdown=0` — record a pixel rectangle.
- `demotape://record/start?nx=&ny=&nw=&nh=` — a normalized (0…1) rectangle.
- `demotape://record/start?mic=1&webcam=0` — override input toggles for this take.
- `demotape://record/stop` — stop; DemoTape auto-renders the styled `.mp4`.

Status is written atomically to `%USERPROFILE%\Videos\DemoTape\.demotape\control.json` (the Windows
analogue of `~/Movies/DemoTape/.demotape/control.json`):

```jsonc
{ "state": "idle|countdown|recording|rendering", "recording": false, "lastOutput": "<path>" }
```

Loop: fire `start` → poll `state:"recording"` → drive → `stop` → poll `state:"idle"` → read
`lastOutput`. From a shell you can open a URL with `Start-Process "demotape://record/stop"`.

> The full command grammar (`cursor`, `type`, `typing`, `cursor/path`, `ui/open|click|find|dump`) is
> **parsed** on Windows (`DemoControl`, unit-tested), and `record/start|stop` is **wired** to the
> recorder. The pointer/keyboard/UI-automation gestures (`SendInput` / UI Automation) are the next
> follow-up; `--encode-frames` (record with no capture permission) is planned alongside them.

## Capture & render pipeline (second vertical slice)

The recording pipeline is implemented in `src/App/Infrastructure`:

| Component | Windows API | macOS analogue |
|-----------|-------------|----------------|
| `ScreenCaptureRecorder` | `Windows.Graphics.Capture` + `MediaStreamSource`/`MediaTranscoder` (Win2D readback) | `AVCaptureScreenInput` |
| `EventRecorder` | `SetWindowsHookEx` (WH_MOUSE_LL/WH_KEYBOARD_LL) + 60 Hz cursor sampler | `NSEvent` monitors |
| `AutoZoomVideoEffect` | Win2D `IBasicVideoEffect` (uses `FocusTimeline`/`SpringCamera`/`CameraViewport`) | Core Image render loop |
| `StyledVideoRenderer` | `MediaComposition.RenderToFileAsync` | `AVAssetReader`→composite→`AVAssetWriter` |
| `CountdownWindow` | borderless click-through WinUI window | `CountdownController` |
| `WindowsRecordingController` | orchestration + state machine | `AppDelegate` |

The auto-zoom math (`FocusTimeline`, `SpringCamera`, `CameraViewport`) and input mapping
(`InputMapping`) live in `Domain` and are fully unit-tested (build/test with just the .NET SDK).

### Known caveat — custom effect activation (unpackaged)

`AutoZoomVideoEffect` is a custom `IBasicVideoEffect`. The media pipeline activates it **by type
name**, which is automatic in an MSIX-packaged app. For the **unpackaged** build this needs regfree
WinRT activation (an `activatableClass` entry). If activation is unavailable at runtime,
`WindowsRecordingController` **falls back to saving the raw capture**, so recording never fails
outright — you simply get the unstyled `.mp4` plus its `.events.json`, which you can then style with
`--render` once activation is configured, or publish as-is.
