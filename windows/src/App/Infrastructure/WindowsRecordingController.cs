using System.Runtime.Versioning;
using DemoTape.App.UI;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Models;
using DemoTape.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.UI.Dispatching;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Orchestrates the capture → auto-render pipeline, mirroring the macOS AppDelegate. The flow:
/// <c>Arm</c> (show the floating control bar + region bounds overlay and warm the webcam/mic) →
/// <c>Start</c> (3-2-1 countdown → capture + event timeline) → <c>Stop</c> (styled render) → notify.
/// Arming warms the camera FIRST and shows the overlay immediately, so there's no cold-start lag.
/// Marshals UI work to the app dispatcher (toggles can arrive from the global hotkey's thread).
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class WindowsRecordingController : IRecordingController
{
    private readonly IServiceProvider _services;
    private readonly IPathService _paths;
    private readonly ISettingsStore _settingsStore;
    private readonly IUserInteraction _interaction;
    private readonly ILogger<WindowsRecordingController> _logger;
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();

    private ScreenCaptureRecorder? _capture;
    private EventRecorder? _events;
    private WebcamRecorder? _webcam;
    private Task<bool>? _webcamPrepare;
    private MicRecorder? _mic;
    private Task<bool>? _micPrepare;
    private string _rawPath = "";
    private string _sidecarPath = "";
    private string? _camPath;
    private string? _micPath;

    // Session UI
    private ControlBarWindow? _bar;
    private RecordingBoundsOverlay? _bounds;
    private FullScreenBorderOverlay? _fullBorder;
    private RegionSelectorOverlay? _selector;
    private TeleprompterWindow? _teleprompter;

    public RecordingState State { get; private set; } = RecordingState.Idle;
    public event Action<RecordingState>? StateChanged;

    public WindowsRecordingController(
        IServiceProvider services, IPathService paths, ISettingsStore settingsStore,
        IUserInteraction interaction, ILogger<WindowsRecordingController> logger)
    {
        _services = services;
        _paths = paths;
        _settingsStore = settingsStore;
        _interaction = interaction;
        _logger = logger;
    }

    public Task ToggleAsync() => State switch
    {
        RecordingState.Idle => StartAsync(),      // arm full screen + countdown + record
        RecordingState.Armed => StartAsync(),     // begin from the armed state
        RecordingState.Recording => StopAsync(),
        _ => Task.CompletedTask,                   // ignore mid-transition
    };

    // ---- Arm ----

    public Task ArmFullScreenAsync()
    {
        var s = _settingsStore.Load();
        s.UseRegion = false;
        _settingsStore.Save(s);
        return ArmAsync(useRegion: false);
    }

    public Task ArmRegionAsync()
    {
        // The selector self-hosts its own message-loop thread; its callback fires on that thread,
        // so ArmAsync (which marshals its own UI work) is safe to call from there.
        _selector?.Dispose();
        _selector = new RegionSelectorOverlay(
            onRegion: region =>
            {
                // Auto-accepted on release. Persist the region; arm (show the bar) the first time,
                // then just keep updating the region as the user resizes/moves it.
                var s = _settingsStore.Load();
                (s.RegionX, s.RegionY, s.RegionW, s.RegionH) = region;
                s.UseRegion = true;
                _settingsStore.Save(s);
                if (State == RecordingState.Idle) _ = ArmAsync(useRegion: true);
            },
            onCancel: () => { _selector = null; _ = CancelAsync(); });
        return Task.CompletedTask;
    }

    /// <summary>Shows the session UI and warms the camera/mic. Idempotent-ish: re-arming re-shows.</summary>
    private Task ArmAsync(bool useRegion)
    {
        return RunOnUiAsync(() =>
        {
            // Warm up ON THE UI THREAD. MediaCapture has thread affinity: arming can be triggered
            // from the region selector's own background thread, and that thread exits when the
            // selector closes — so a mic/webcam initialized there would be dead by the time capture
            // begins (silent audio). Kicking the prepares off here keeps them on the durable UI thread.
            _webcamPrepare = PrepareWebcamAsync();
            _micPrepare = PrepareMicAsync();

            // Show the control bar. (For region mode the interactive selector already shows the
            // area and stays editable until Start; the click-through bounds overlay is created when
            // recording actually begins.)
            if (_bar is null)
            {
                _bar = new ControlBarWindow(this, _settingsStore);
                _bar.Closed += (_, _) => _bar = null;
                _bar.Activate();
                _logger.LogInformation("Control bar shown (armed, region={Region})", useRegion);
            }

            // The selector overlay is a full-screen topmost window that would sit ON TOP of the bar,
            // making it unclickable. Push the selector just BELOW the bar so the bar is interactive.
            try
            {
                var barHwnd = WinRT.Interop.WindowNative.GetWindowHandle(_bar);
                SetWindowPos(barHwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                if (_selector is not null && _selector.Hwnd != IntPtr.Zero)
                    SetWindowPos(_selector.Hwnd, barHwnd, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            }
            catch (Exception ex) { _logger.LogWarning(ex, "z-order reorder failed"); }

            SetState(RecordingState.Armed);
            return Task.CompletedTask;
        });
    }

    // ---- Start / capture ----

    public async Task StartAsync()
    {
        if (State == RecordingState.Idle)
        {
            await ArmAsync(_settingsStore.Load().UseRegion);
        }
        if (State != RecordingState.Armed) return;

        // Lock the region: close the interactive selector so it can't be changed mid-recording.
        _selector?.Dispose();
        _selector = null;

        SetState(RecordingState.Countdown);
        await RunOnUiAsync(async () =>
        {
            var countdown = new CountdownWindow();
            await countdown.RunAsync(3, BeginCaptureAsync);
        });
    }

    private async Task<bool> PrepareWebcamAsync()
    {
        var settings = _settingsStore.Load();
        if (!settings.CaptureWebcam) { _webcam = null; return false; }

        if (!CameraAllowed())
        {
            _ = _interaction.ShowMessageAsync("Enable camera access",
                "Windows is blocking the camera for desktop apps, so the webcam records a blank frame. " +
                "Turn on Settings → Privacy & security → Camera → \"Let desktop apps access your camera\" " +
                "(and \"Camera access\"), then record again.");
            OpenCameraPrivacySettings();
        }

        _webcam = _services.GetRequiredService<WebcamRecorder>();
        if (await _webcam.PrepareAsync(withMicrophone: false)) return true;
        _webcam = null;
        return false;
    }

    private async Task<bool> PrepareMicAsync()
    {
        var settings = _settingsStore.Load();
        if (!settings.CaptureMicrophone) { _mic = null; return false; }
        _mic = _services.GetRequiredService<MicRecorder>();
        if (await _mic.PrepareAsync()) return true;
        _mic = null;
        return false;
    }

    private async Task BeginCaptureAsync()
    {
        try
        {
            _rawPath = MakeOutputPath();
            _sidecarPath = _rawPath[..^".mp4".Length] + ".events.json";

            _capture = _services.GetRequiredService<ScreenCaptureRecorder>();
            _capture.Start(_rawPath); // full-screen capture; region is cropped at render time

            var settings = _settingsStore.Load();

            // Begin the (already-warmed) webcam + mic recordings — fast, aligned with the screen.
            _camPath = null;
            bool camReady = _webcamPrepare is not null && await _webcamPrepare;
            if (camReady && _webcam is not null)
            {
                var cam = _rawPath[..^".mp4".Length] + ".cam.mp4";
                if (await _webcam.BeginAsync(cam)) _camPath = cam;
                else _webcam = null;
            }
            else _webcam = null;

            _micPath = null;
            bool micReady = _micPrepare is not null && await _micPrepare;
            if (micReady && _mic is not null)
            {
                var mic = _rawPath[..^".mp4".Length] + ".mic.m4a";
                if (await _mic.BeginAsync(mic)) _micPath = mic;
                else _mic = null;
            }
            else _mic = null;

            _events = _services.GetRequiredService<EventRecorder>();
            var display = BuildDisplay();
            (double X, double Y, double W, double H) region =
                settings.UseRegion && settings.RegionW > 0 && settings.RegionH > 0
                    ? (settings.RegionX * display.PixelWidth, settings.RegionY * display.PixelHeight,
                       settings.RegionW * display.PixelWidth, settings.RegionH * display.PixelHeight)
                    : (0.0, 0.0, display.PixelWidth, display.PixelHeight);
            _events.Start(region, display);

            // Recording cue (excluded from capture): a blue frame around the region, or a blue
            // border around the whole screen for full-screen capture.
            bool regionMode = settings.UseRegion && settings.RegionW > 0 && settings.RegionH > 0;
            await RunOnUiAsync(() =>
            {
                if (regionMode)
                    _bounds = new RecordingBoundsOverlay(settings.RegionX, settings.RegionY, settings.RegionW, settings.RegionH);
                else
                    _fullBorder = new FullScreenBorderOverlay();

                // Teleprompter (excluded from capture) — scrolls the script while recording.
                if (settings.TeleprompterEnabled && !string.IsNullOrWhiteSpace(settings.TeleprompterScript))
                {
                    _teleprompter = new TeleprompterWindow(settings);
                    _teleprompter.Activate();
                }
                return Task.CompletedTask;
            });

            SetState(RecordingState.Recording);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to start capture");
            CloseSessionUi();
            SetState(RecordingState.Idle);
            _ = _interaction.ShowMessageAsync("Can't start recording", ex.Message);
        }
    }

    // ---- Stop / cancel ----

    public async Task StopAsync()
    {
        if (State != RecordingState.Recording) return;
        CloseSessionUi();
        SetState(RecordingState.Rendering);
        try
        {
            double eventOffset = 0;
            if (_capture is not null && _events is not null && _capture.FirstFrameTime != TimeSpan.MinValue)
                eventOffset = _capture.FirstFrameTime.TotalSeconds - _events.StartTimestampSeconds;

            var result = _capture is null ? null : await _capture.StopAsync();
            var camPath = _webcam is null ? null : await _webcam.StopAsync();
            var micPath = _mic is null ? null : await _mic.StopAsync();
            _events?.Stop(_rawPath, cameraOffset: 0, eventOffset: eventOffset);

            if (result is null)
            {
                SetState(RecordingState.Idle);
                await _interaction.ShowMessageAsync("No video was captured",
                    "The recording was empty. Check that a display is available for capture.");
                return;
            }

            var settings = _settingsStore.Load();

            // On-device audio cleanup (denoise → enhance) applied to the mic in place BEFORE muxing,
            // so there's no extra video pass. Best-effort; matches the macOS "in place" behavior.
            if (micPath is not null && (settings.NoiseSuppression || settings.EnhanceVoice))
            {
                _logger.LogInformation("Cleaning up audio…");
                await _services.GetRequiredService<AudioEnhancementService>()
                    .ProcessInPlaceAsync(micPath, settings.NoiseSuppression, settings.EnhanceVoice);
            }

            var styledPath = _rawPath[..^".mp4".Length] + ".styled.mp4";
            var renderer = _services.GetRequiredService<StyledVideoRenderer>();
            _logger.LogInformation("Rendering styled output…");
            var styled = await renderer.RenderAsync(_rawPath, _sidecarPath, styledPath, settings,
                cameraPath: camPath, micPath: micPath);

            SetState(RecordingState.Idle);
            var final = styled ?? _rawPath;
            _interaction.RevealInExplorer(final);
            _interaction.Notify(
                styled is not null ? "Recording ready" : "Recording saved (unstyled)",
                Path.GetFileName(final));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Stop/render failed");
            SetState(RecordingState.Idle);
            await _interaction.ShowMessageAsync("Recording error", ex.Message);
        }
        finally
        {
            _capture = null; _events = null; _webcam = null; _mic = null;
        }
    }

    public async Task CancelAsync()
    {
        var wasRecording = State == RecordingState.Recording;
        CloseSessionUi();
        try
        {
            if (wasRecording)
            {
                if (_capture is not null) await _capture.StopAsync();
                if (_webcam is not null) await _webcam.StopAsync();
                if (_mic is not null) await _mic.StopAsync();
                _events?.Stop(_rawPath, 0, 0);
                DeleteQuietly(_rawPath, _sidecarPath, _camPath, _micPath);
            }
            else
            {
                // Armed but never started: release the warmed sessions.
                if (_webcam is not null) await _webcam.StopAsync();
                if (_mic is not null) await _mic.StopAsync();
            }
        }
        catch (Exception ex) { _logger.LogWarning(ex, "Cancel cleanup issue"); }
        finally
        {
            _capture = null; _events = null; _webcam = null; _mic = null;
            _webcamPrepare = null; _micPrepare = null;
            SetState(RecordingState.Idle);
        }
    }

    // ---- Session UI helpers ----

    private void CloseSessionUi()
    {
        _dispatcher.TryEnqueue(() =>
        {
            try { _selector?.Dispose(); } catch { }
            try { _bounds?.Dispose(); } catch { }
            try { _fullBorder?.Dispose(); } catch { }
            try { _teleprompter?.Close(); } catch { }
            try { _bar?.Close(); } catch { }
            _selector = null; _bounds = null; _fullBorder = null; _teleprompter = null; _bar = null;
        });
    }

    private void CloseBounds()
    {
        try { _bounds?.Dispose(); } catch { }
        _bounds = null;
    }

    private static void DeleteQuietly(params string?[] paths)
    {
        foreach (var p in paths)
        {
            if (string.IsNullOrEmpty(p)) continue;
            try { if (File.Exists(p)) File.Delete(p); } catch { }
        }
    }

    private static bool CameraAllowed()
    {
        try
        {
            var status = Windows.Security.Authorization.AppCapabilityAccess.AppCapability
                .Create("webcam").CheckAccess();
            return status == Windows.Security.Authorization.AppCapabilityAccess.AppCapabilityAccessStatus.Allowed;
        }
        catch { return true; } // check unsupported → let MediaCapture try
    }

    private void OpenCameraPrivacySettings()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
                "ms-settings:privacy-webcam") { UseShellExecute = true });
        }
        catch { /* best effort */ }
    }

    private DisplayInfo BuildDisplay()
    {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1); // physical pixels (DPI-aware manifest)
        return new DisplayInfo { PixelWidth = w, PixelHeight = h, PointWidth = w, PointHeight = h, Scale = 1 };
    }

    private string MakeOutputPath()
    {
        var name = $"DemoTape {DateTime.Now:yyyy-MM-dd 'at' HH.mm.ss}.mp4";
        return Path.Combine(_paths.OutputDirectory, name);
    }

    private void SetState(RecordingState state)
    {
        State = state;
        StateChanged?.Invoke(state);
    }

    private Task RunOnUiAsync(Func<Task> work)
    {
        var tcs = new TaskCompletionSource();
        if (!_dispatcher.TryEnqueue(async () =>
        {
            try { await work(); tcs.SetResult(); }
            catch (Exception ex) { tcs.SetException(ex); }
        }))
        {
            tcs.SetException(new InvalidOperationException("UI dispatcher unavailable."));
        }
        return tcs.Task;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010;
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
