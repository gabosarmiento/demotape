using System.Runtime.Versioning;
using Microsoft.Extensions.Logging;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Storage;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Records the webcam to its own file in parallel with the screen capture, so the renderer can
/// composite it as a circular picture-in-picture. The Windows analogue of the macOS
/// <c>CameraRecorder</c>. Fails gracefully (returns false) if no camera or access is denied.
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class WebcamRecorder
{
    private readonly ILogger<WebcamRecorder> _logger;
    private MediaCapture? _capture;
    private string? _path;
    private bool _recording;

    public WebcamRecorder(ILogger<WebcamRecorder> logger) => _logger = logger;

    /// <summary>Starts recording the webcam to <paramref name="camPath"/> (.mp4). Returns false if unavailable.</summary>
    public async Task<bool> StartAsync(string camPath, bool withMicrophone)
    {
        try
        {
            var init = new MediaCaptureInitializationSettings
            {
                StreamingCaptureMode = withMicrophone ? StreamingCaptureMode.AudioAndVideo : StreamingCaptureMode.Video,
                MediaCategory = MediaCategory.Media,
            };
            _capture = new MediaCapture();
            await _capture.InitializeAsync(init);

            var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD720p);
            var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(camPath)!);
            var file = await folder.CreateFileAsync(Path.GetFileName(camPath), CreationCollisionOption.ReplaceExisting);
            await _capture.StartRecordToStorageFileAsync(profile, file);

            _path = camPath;
            _recording = true;
            _logger.LogInformation("Webcam recording -> {Name}", Path.GetFileName(camPath));
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Webcam unavailable; continuing without it");
            Cleanup();
            return false;
        }
    }

    /// <summary>Stops and finalizes the webcam file. Returns its path, or null on failure.</summary>
    public async Task<string?> StopAsync()
    {
        try
        {
            if (_capture is not null && _recording) await _capture.StopRecordAsync();
        }
        catch (Exception ex) { _logger.LogWarning(ex, "Webcam stop failed"); }

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
