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
    private string _rawPath = "";
    private string _sidecarPath = "";

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
        return RunOnUiAsync(async () =>
        {
            var countdown = new CountdownWindow();
            await countdown.RunAsync(3, BeginCaptureAsync);
        });
    }

    private Task BeginCaptureAsync()
    {
        try
        {
            _rawPath = MakeOutputPath();
            _sidecarPath = _rawPath[..^".mp4".Length] + ".events.json";

            _capture = _services.GetRequiredService<ScreenCaptureRecorder>();
            _capture.Start(_rawPath); // full-screen capture (region framing is a later enhancement)

            _events = _services.GetRequiredService<EventRecorder>();
            var display = BuildDisplay();
            var region = (0.0, 0.0, display.PixelWidth, display.PixelHeight);
            _events.Start(region, display);

            SetState(RecordingState.Recording);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to start capture");
            SetState(RecordingState.Idle);
            _ = _interaction.ShowMessageAsync("Can't start recording", ex.Message);
        }
        return Task.CompletedTask;
    }

    private async Task StopAsync()
    {
        SetState(RecordingState.Rendering);
        try
        {
            var result = _capture is null ? null : await _capture.StopAsync();
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
            var styled = await renderer.RenderAsync(_rawPath, _sidecarPath, styledPath, settings);

            SetState(RecordingState.Idle);
            _interaction.RevealInExplorer(styled ?? _rawPath);
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
        }
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
