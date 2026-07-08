# Building & running DemoTape for Windows

## What builds where

The Windows port is split so that **all business logic builds and tests with only the .NET SDK**,
while the WinUI 3 desktop shell requires the Windows App SDK tooling.

| Project | Target | Needs |
|---------|--------|-------|
| `src/App/Domain/DemoTape.Domain.csproj` | `net8.0` | .NET 8 SDK only |
| `src/App/ViewModels/DemoTape.ViewModels.csproj` | `net8.0` | .NET 8 SDK only |
| `tests/DemoTape.Tests/DemoTape.Tests.csproj` | `net8.0` | .NET 8 SDK only |
| `src/App/DemoTape.App.csproj` | `net8.0-windows10.0.19041.0` (WinUI 3) | .NET 8 SDK + **Windows SDK** + Windows App SDK |

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
```

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
