using System.Runtime.InteropServices;
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
        _device = CanvasDevice.GetSharedDevice();

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

        _framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
            _device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
        _framePool.FrameArrived += OnFrameArrived;

        _session = _framePool.CreateCaptureSession(_item);
        TrySet(() => _session.IsCursorCaptureEnabled = false);  // we draw a synthetic cursor
        TrySet(() => _session.IsBorderRequired = false);        // no yellow capture border (1809+)

        _encodeTask = Task.Run(EncodeAsync);
        _session.StartCapture();
        _logger.LogInformation("Screen capture started {W}x{H} @ scale {S}", _width, _height, _scale);
    }

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        using var frame = sender.TryGetNextFrame();
        if (frame is null || _device is null || _frames is null) return;
        if (_firstFrameTime == TimeSpan.MinValue) _firstFrameTime = frame.SystemRelativeTime;

        using var bitmap = CanvasBitmap.CreateFromDirect3D11Surface(_device, frame.Surface);
        var bytes = bitmap.GetPixelBytes(); // BGRA8
        _frames.Writer.TryWrite((bytes, frame.SystemRelativeTime - _firstFrameTime));
    }

    private async Task EncodeAsync()
    {
        if (_frames is null) return;
        var reader = _frames.Reader;

        var videoProps = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)_width, (uint)_height);
        var descriptor = new VideoStreamDescriptor(videoProps);
        var mss = new MediaStreamSource(descriptor)
        {
            BufferTime = TimeSpan.Zero,
            IsLive = true,
        };

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

        var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
        profile.Video = VideoEncodingProperties.CreateH264();
        profile.Video.Width = (uint)_width;
        profile.Video.Height = (uint)_height;
        profile.Video.Bitrate = (uint)(_width * _height * 8);
        profile.Audio = null; // raw screen has no audio; mic is captured/muxed separately

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
