using System.Numerics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Runtime.Versioning;
using System.Threading.Channels;
using Microsoft.Extensions.Logging;
using Microsoft.Graphics.Canvas;
using Windows.Foundation;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.Streams;

namespace DemoTape.App.Infrastructure;

/// <summary>Result of a raw screen capture: the output file plus the region (screen pixels) captured.</summary>
public sealed record CaptureResult(string VideoPath, double RegionX, double RegionY, double RegionW, double RegionH,
    double PixelWidth, double PixelHeight, double Scale);

/// <summary>
/// Records a display to a raw H.264 MP4 using <see cref="GraphicsCaptureItem"/> +
/// <see cref="Direct3D11CaptureFramePool"/> (the Windows analogue of macOS
/// <c>AVCaptureScreenInput</c>). Frames are read back with Win2D and fed to a
/// <see cref="MediaStreamSource"/> that a <see cref="MediaTranscoder"/> encodes to disk.
/// ScreenCaptureKit's macOS caveats don't apply here — Graphics Capture is the supported path
/// on Windows 10 1903+.
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class ScreenCaptureRecorder
{
    private readonly ILogger<ScreenCaptureRecorder> _logger;

    private CanvasDevice? _device;
    private Direct3D11CaptureFramePool? _framePool;
    private GraphicsCaptureSession? _session;
    private GraphicsCaptureItem? _item;
    private Channel<(byte[] Bgra, TimeSpan Time)>? _frames;
    private CanvasRenderTarget? _flipTarget;
    private readonly object _flipLock = new();
    private TimeSpan _firstFrameTime = TimeSpan.MinValue;
    private int _width, _height;
    private Task? _encodeTask;
    private string _outputPath = "";
    private (double X, double Y, double W, double H) _region;
    private double _scale = 1;

    public ScreenCaptureRecorder(ILogger<ScreenCaptureRecorder> logger) => _logger = logger;

    /// <summary>Wall-clock-independent time of the first captured frame, for event alignment.</summary>
    public TimeSpan FirstFrameTime => _firstFrameTime;

    /// <summary>Starts capturing the primary monitor to <paramref name="outputPath"/> (an .mp4).</summary>
    public void Start(string outputPath, (double X, double Y, double W, double H)? region = null)
    {
        _outputPath = outputPath;
        // A DEDICATED device (not the shared one WinUI renders with) so the free-threaded capture
        // callback never contends with the UI thread's GPU work — that contention was hanging the
        // UI thread and causing the shell to drop the tray icon.
        _device = new CanvasDevice();

        var hmon = MonitorFromPoint(new POINT { X = 0, Y = 0 }, MONITOR_DEFAULTTOPRIMARY);
        _item = CreateItemForMonitor(hmon);
        var size = _item.Size;
        _width = size.Width; _height = size.Height;
        _scale = GetDpiScale(hmon);
        _region = region ?? (0, 0, _width, _height);

        _frames = Channel.CreateBounded<(byte[], TimeSpan)>(new BoundedChannelOptions(120)
        {
            FullMode = BoundedChannelFullMode.DropWrite, // never block the capture callback
            SingleReader = true,
        });

        // Reused target for the per-frame vertical flip (Media Foundation reads BGRA bottom-up).
        _flipTarget = new CanvasRenderTarget(_device, _width, _height, 96);

        _framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
            _device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
        _framePool.FrameArrived += OnFrameArrived;

        _session = _framePool.CreateCaptureSession(_item);
        TrySet(() => _session.IsCursorCaptureEnabled = false);  // we draw a synthetic cursor

        _encodeTask = Task.Run(EncodeAsync);
        _session.StartCapture();
        _logger.LogInformation("Screen capture started {W}x{H} @ scale {S}", _width, _height, _scale);
    }

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        try
        {
            using var frame = sender.TryGetNextFrame();
            if (frame is null || _device is null || _frames is null || _flipTarget is null) return;
            if (_firstFrameTime == TimeSpan.MinValue) _firstFrameTime = frame.SystemRelativeTime;

            using var bitmap = CanvasBitmap.CreateFromDirect3D11Surface(_device, frame.Surface);
            byte[] bytes;
            lock (_flipLock)
            {
                // Draw the frame flipped vertically (scale Y by -1, shift down by height) so the
                // top-down capture becomes the bottom-up layout the H.264 encoder expects.
                using (var ds = _flipTarget.CreateDrawingSession())
                {
                    ds.Transform = Matrix3x2.CreateScale(1, -1) * Matrix3x2.CreateTranslation(0, _height);
                    ds.DrawImage(bitmap);
                }
                bytes = _flipTarget.GetPixelBytes();
            }
            _frames.Writer.TryWrite((bytes, frame.SystemRelativeTime - _firstFrameTime));
        }
        catch (Exception ex)
        {
            // Never let a transient frame error crash the capture callback thread.
            _logger.LogWarning(ex, "Frame processing skipped");
        }
    }

    private async Task EncodeAsync()
    {
        if (_frames is null) return;
        var reader = _frames.Reader;

        // Input: uncompressed BGRA frames. Frame rate + pixel-aspect MUST be set or the encoder
        // rejects the media type (MF_E_*).
        var videoProps = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)_width, (uint)_height);
        videoProps.FrameRate.Numerator = 30;
        videoProps.FrameRate.Denominator = 1;
        videoProps.PixelAspectRatio.Numerator = 1;
        videoProps.PixelAspectRatio.Denominator = 1;
        var descriptor = new VideoStreamDescriptor(videoProps);
        var mss = new MediaStreamSource(descriptor);

        mss.SampleRequested += async (s, e) =>
        {
            var deferral = e.Request.GetDeferral();
            try
            {
                if (await reader.WaitToReadAsync().ConfigureAwait(false) && reader.TryRead(out var f))
                {
                    var buffer = f.Bgra.AsBuffer();
                    var sample = MediaStreamSample.CreateFromBuffer(buffer, f.Time);
                    sample.Duration = TimeSpan.FromSeconds(1.0 / 30);
                    e.Request.Sample = sample;
                }
                else
                {
                    e.Request.Sample = null; // end of stream
                }
            }
            finally { deferral.Complete(); }
        };

        // Output: build a coherent H.264 MP4 profile with explicit dimensions + frame rate.
        var h264 = VideoEncodingProperties.CreateH264();
        h264.Width = (uint)_width;
        h264.Height = (uint)_height;
        h264.Bitrate = (uint)(_width * _height * 8);
        h264.FrameRate.Numerator = 30;
        h264.FrameRate.Denominator = 1;
        h264.PixelAspectRatio.Numerator = 1;
        h264.PixelAspectRatio.Denominator = 1;
        var profile = new MediaEncodingProfile
        {
            Container = new ContainerEncodingProperties { Subtype = MediaEncodingSubtypes.Mpeg4 },
            Video = h264,
            Audio = null, // raw screen has no audio; mic is captured/muxed separately
        };

        var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(_outputPath)!);
        var file = await folder.CreateFileAsync(Path.GetFileName(_outputPath), CreationCollisionOption.ReplaceExisting);
        using var stream = await file.OpenAsync(FileAccessMode.ReadWrite);

        var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
        var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(mss, stream, profile);
        if (!prepared.CanTranscode)
        {
            _logger.LogError("Cannot encode capture: {Reason}", prepared.FailureReason);
            return;
        }
        await prepared.TranscodeAsync();
        _logger.LogInformation("Raw capture encoded -> {Name}", Path.GetFileName(_outputPath));
    }

    /// <summary>Stops capture, finalizes the file, and returns the result.</summary>
    public async Task<CaptureResult?> StopAsync()
    {
        _session?.Dispose();
        _framePool?.Dispose();
        _frames?.Writer.TryComplete();
        if (_encodeTask is not null)
        {
            try { await _encodeTask.ConfigureAwait(false); }
            catch (Exception ex) { _logger.LogError(ex, "Encode task failed"); }
        }
        _session = null; _framePool = null; _item = null;
        _flipTarget?.Dispose();
        _flipTarget = null;
        _device?.Dispose();
        _device = null;

        if (!File.Exists(_outputPath) || new FileInfo(_outputPath).Length == 0) return null;
        return new CaptureResult(_outputPath, _region.X, _region.Y, _region.W, _region.H,
            _width, _height, _scale);
    }

    private static void TrySet(Action set) { try { set(); } catch { /* older Windows build */ } }

    // ---- Graphics Capture interop ----

    // The ABI GUID of GraphicsCaptureItem (used to marshal the interop-created object).
    private static readonly Guid GraphicsCaptureItemIid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    private static GraphicsCaptureItem CreateItemForMonitor(IntPtr hmon)
    {
        // Canonical C#/WinRT pattern: get the activation factory, cast to the interop interface,
        // create the item for the monitor, then marshal the returned ABI pointer.
        var factory = WinRT.ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
        var interop = factory.AsInterface<IGraphicsCaptureItemInterop>();
        var iid = GraphicsCaptureItemIid;
        var itemPtr = interop.CreateForMonitor(hmon, ref iid);
        try { return GraphicsCaptureItem.FromAbi(itemPtr); }
        finally { Marshal.Release(itemPtr); }
    }

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IGraphicsCaptureItemInterop
    {
        IntPtr CreateForWindow(IntPtr window, ref Guid iid);
        IntPtr CreateForMonitor(IntPtr monitor, ref Guid iid);
    }

    private static double GetDpiScale(IntPtr hmon)
    {
        try
        {
            GetDpiForMonitor(hmon, 0 /* MDT_EFFECTIVE_DPI */, out uint dpiX, out _);
            return dpiX / 96.0;
        }
        catch { return 1.0; }
    }

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
    private const uint MONITOR_DEFAULTTOPRIMARY = 1;

    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);
}
