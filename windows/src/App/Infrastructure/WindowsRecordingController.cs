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
/// Orchestrates the full capture → auto-render pipeline, mirroring the macOS AppDelegate:
/// 3-2-1 countdown → start screen capture + event timeline → stop → styled render → notify.
/// Marshals UI work (countdown window) to the app's dispatcher because the toggle can arrive
/// from the global hotkey's background thread.
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
    private string _rawPath = "";
    private string _sidecarPath = "";
    private string? _camPath;

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
        RecordingState.Idle => StartAsync(),
        RecordingState.Recording => StopAsync(),
        _ => Task.CompletedTask, // ignore mid-transition
    };

    private Task StartAsync()
    {
        SetState(RecordingState.Countdown);
        // Warm up the webcam concurrently with the countdown so recording begins instantly at
        // zero (no camera cold-start lag / black frames) — matches the macOS behavior.
        _webcamPrepare = PrepareWebcamAsync();
        return RunOnUiAsync(async () =>
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

    private async Task BeginCaptureAsync()
    {
        try
        {
            _rawPath = MakeOutputPath();
            _sidecarPath = _rawPath[..^".mp4".Length] + ".events.json";

            _capture = _services.GetRequiredService<ScreenCaptureRecorder>();
            _capture.Start(_rawPath); // full-screen capture

            var settings = _settingsStore.Load();

            // Begin the (already-warmed) webcam recording — fast, so it's aligned with the screen.
            _camPath = null;
            bool camReady = _webcamPrepare is not null && await _webcamPrepare;
            if (camReady && _webcam is not null)
            {
                var cam = _rawPath[..^".mp4".Length] + ".cam.mp4";
                if (await _webcam.BeginAsync(cam)) _camPath = cam;
                else _webcam = null;
            }
            else _webcam = null;

            _events = _services.GetRequiredService<EventRecorder>();
            var display = BuildDisplay();
            (double X, double Y, double W, double H) region =
                settings.UseRegion && settings.RegionW > 0 && settings.RegionH > 0
                    ? (settings.RegionX * display.PixelWidth, settings.RegionY * display.PixelHeight,
                       settings.RegionW * display.PixelWidth, settings.RegionH * display.PixelHeight)
                    : (0.0, 0.0, display.PixelWidth, display.PixelHeight);
            _events.Start(region, display);

            SetState(RecordingState.Recording);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to start capture");
            SetState(RecordingState.Idle);
            _ = _interaction.ShowMessageAsync("Can't start recording", ex.Message);
        }
    }

    private async Task StopAsync()
    {
        SetState(RecordingState.Rendering);
        try
        {
            var result = _capture is null ? null : await _capture.StopAsync();
            var camPath = _webcam is null ? null : await _webcam.StopAsync();
            _events?.Stop(_rawPath, cameraOffset: 0, eventOffset: 0);

            if (result is null)
            {
                SetState(RecordingState.Idle);
                await _interaction.ShowMessageAsync("No video was captured",
                    "The recording was empty. Check that a display is available for capture.");
                return;
            }

            // Auto-produce the styled output (hands-off), falling back to raw on failure.
            var settings = _settingsStore.Load();
            var styledPath = _rawPath[..^".mp4".Length] + ".styled.mp4";
            var renderer = _services.GetRequiredService<StyledVideoRenderer>();
            _logger.LogInformation("Rendering styled output…");
            var styled = await renderer.RenderAsync(_rawPath, _sidecarPath, styledPath, settings, cameraPath: camPath);

            SetState(RecordingState.Idle);
            var final = styled ?? _rawPath;
            _interaction.RevealInExplorer(final);
            await _interaction.ShowMessageAsync(
                styled is not null ? "Recording styled & saved" : "Recording saved (unstyled)",
                final);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Stop/render failed");
            SetState(RecordingState.Idle);
            await _interaction.ShowMessageAsync("Recording error", ex.Message);
        }
        finally
        {
            _capture = null;
            _events = null;
            _webcam = null;
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
        return new DisplayInfo
        {
            PixelWidth = w,
            PixelHeight = h,
            PointWidth = w,
            PointHeight = h,
            Scale = 1,
        };
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
}
