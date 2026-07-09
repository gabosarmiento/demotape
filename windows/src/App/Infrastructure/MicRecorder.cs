using System.Runtime.Versioning;
using Microsoft.Extensions.Logging;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Storage;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Records the microphone to its own <c>.mic.m4a</c> file in parallel with the screen capture; the
/// renderer muxes it into the styled output. Split into Prepare (warm up during the countdown) and
/// Begin (start at zero) like the webcam. Fails gracefully if no mic / access denied.
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class MicRecorder
{
    private readonly ILogger<MicRecorder> _logger;
    private MediaCapture? _capture;
    private string? _path;
    private bool _recording;

    public MicRecorder(ILogger<MicRecorder> logger) => _logger = logger;

    public async Task<bool> PrepareAsync()
    {
        try
        {
            _capture = new MediaCapture();
            await _capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                StreamingCaptureMode = StreamingCaptureMode.Audio,
                MediaCategory = MediaCategory.Media,
            });
            _logger.LogInformation("Microphone prepared");
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Microphone unavailable; continuing without it");
            Cleanup();
            return false;
        }
    }

    public async Task<bool> BeginAsync(string path)
    {
        if (_capture is null) return false;
        try
        {
            var profile = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.Medium);
            var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(path)!);
            var file = await folder.CreateFileAsync(Path.GetFileName(path), CreationCollisionOption.ReplaceExisting);
            await _capture.StartRecordToStorageFileAsync(profile, file);
            _path = path;
            _recording = true;
            _logger.LogInformation("Microphone recording -> {Name}", Path.GetFileName(path));
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Microphone begin failed");
            return false;
        }
    }

    public async Task<string?> StopAsync()
    {
        try { if (_capture is not null && _recording) await _capture.StopRecordAsync(); }
        catch (Exception ex) { _logger.LogWarning(ex, "Microphone stop failed"); }

        var path = _path;
        Cleanup();
        return path is not null && File.Exists(path) ? path : null;
    }

    private void Cleanup()
    {
        _recording = false;
        try { _capture?.Dispose(); } catch { }
        _capture = null;
        _path = null;
    }
}
