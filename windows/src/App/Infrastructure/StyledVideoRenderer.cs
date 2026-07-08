using System.Numerics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using System.Threading.Channels;
using DemoTape.Domain.Models;
using DemoTape.Domain.Rendering;
using DemoTape.Domain.Settings;
using Microsoft.Extensions.Logging;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Core;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.UI;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Renders a raw screen capture + its event sidecar into DemoTape's auto-styled MP4 — the Windows
/// analogue of the macOS <c>VideoRenderer</c>. Applies spring-smoothed auto-zoom, a synthetic
/// cursor, click ripples, and keyboard-shortcut badges using the unit-tested
/// <see cref="FocusTimeline"/>/<see cref="SpringCamera"/>/<see cref="CameraViewport"/>.
///
/// Frames are decoded with <c>MediaComposition.GetThumbnailAsync</c>, composited with Win2D, and
/// encoded with the same MediaStreamSource/MediaTranscoder path used by capture. This avoids a
/// custom <c>IBasicVideoEffect</c> (which can't be activated in an unpackaged app).
/// </summary>
public sealed class StyledVideoRenderer
{
    private const double Fps = 30;
    private const double RippleDuration = 0.5;

    private readonly ILogger<StyledVideoRenderer> _logger;

    public StyledVideoRenderer(ILogger<StyledVideoRenderer> logger) => _logger = logger;

    public async Task<string?> RenderAsync(string rawPath, string sidecarPath, string outPath, AppSettings settings)
    {
        try
        {
            RecordingMetadata? meta = null;
            if (File.Exists(sidecarPath))
                meta = JsonSerializer.Deserialize<RecordingMetadata>(await File.ReadAllTextAsync(sidecarPath),
                    new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
            meta ??= new RecordingMetadata();

            var rawFile = await StorageFile.GetFileFromPathAsync(rawPath);
            var vp = await rawFile.Properties.GetVideoPropertiesAsync();
            int W = Even(vp.Width != 0 ? (int)vp.Width : (int)meta.Display.PixelWidth);
            int H = Even(vp.Height != 0 ? (int)vp.Height : (int)meta.Display.PixelHeight);
            if (W <= 0 || H <= 0) { _logger.LogError("Styled render: unknown source size"); return null; }

            var clip = await MediaClip.CreateFromFileAsync(rawFile);
            var comp = new MediaComposition();
            comp.Clips.Add(clip);
            double durationSec = comp.Duration.TotalSeconds;
            if (durationSec <= 0) durationSec = meta.Duration;
            int totalFrames = Math.Max(1, (int)(durationSec * Fps));

            var focus = new FocusTimeline(meta, maxZoom: 2.0);
            var camera = new SpringCamera();
            var viewport = new CameraViewport(W, H);
            double eventOffset = meta.EventTimeOffset ?? 0;

            using var device = new CanvasDevice();
            using var compRT = new CanvasRenderTarget(device, W, H, 96);
            using var flipRT = new CanvasRenderTarget(device, W, H, 96);
            using var cursorImg = MakeCursor(device);

            var channel = Channel.CreateBounded<(byte[] Bgra, TimeSpan Time)>(
                new BoundedChannelOptions(8) { FullMode = BoundedChannelFullMode.Wait, SingleReader = true, SingleWriter = true });
            var encodeTask = EncodeAsync(channel.Reader, W, H, outPath);

            for (int i = 0; i < totalFrames; i++)
            {
                double t = i / Fps;
                double eventT = t + eventOffset;
                var thumbTime = TimeSpan.FromSeconds(Math.Min(t, Math.Max(0, durationSec - 0.01)));

                using var stream = await comp.GetThumbnailAsync(thumbTime, W, H, VideoFramePrecision.NearestFrame);
                var decoder = await BitmapDecoder.CreateAsync(stream);
                using var sb = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
                using var srcBitmap = CanvasBitmap.CreateFromSoftwareBitmap(device, sb);

                var targetFocus = focus.Target(eventT);
                camera.Step(targetFocus, 1.0 / Fps);
                var view = viewport.ComputeViewport(camera.Scale, camera.CenterX, camera.CenterY);

                using (var ds = compRT.CreateDrawingSession())
                {
                    ds.Clear(Colors.Black);
                    // Auto-zoom: draw the source viewport region stretched to fill the output.
                    ds.DrawImage(srcBitmap,
                        new Rect(0, 0, W, H),
                        new Rect(view.OffsetX, view.OffsetY, view.Width, view.Height));

                    if (settings.ShowShortcutBadges || true) // ripples/cursor always on
                    {
                        DrawRipples(ds, meta, viewport, camera.Scale, view, eventT, W);
                        DrawCursor(ds, cursorImg, focus, viewport, camera.Scale, view, eventT);
                    }
                    if (settings.ShowShortcutBadges)
                    {
                        var label = focus.ShortcutBadge(eventT);
                        if (label is not null) DrawBadge(ds, label, W, H);
                    }
                }

                // Flip vertically so the encoder's bottom-up BGRA read yields the correct orientation.
                using (var ds = flipRT.CreateDrawingSession())
                {
                    ds.Transform = Matrix3x2.CreateScale(1, -1) * Matrix3x2.CreateTranslation(0, H);
                    ds.DrawImage(compRT);
                }

                await channel.Writer.WriteAsync((flipRT.GetPixelBytes(), TimeSpan.FromSeconds(t)));
            }
            channel.Writer.Complete();
            await encodeTask;

            _logger.LogInformation("Styled render complete ({Frames} frames) -> {Name}", totalFrames, Path.GetFileName(outPath));
            return outPath;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Styled render failed; falling back to raw");
            return null;
        }
    }

    // ---- Encoder (same MediaStreamSource + MediaTranscoder path used by capture) ----

    private async Task EncodeAsync(ChannelReader<(byte[] Bgra, TimeSpan Time)> reader, int width, int height, string outPath)
    {
        var inProps = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)width, (uint)height);
        inProps.FrameRate.Numerator = 30; inProps.FrameRate.Denominator = 1;
        inProps.PixelAspectRatio.Numerator = 1; inProps.PixelAspectRatio.Denominator = 1;
        var mss = new MediaStreamSource(new VideoStreamDescriptor(inProps));

        mss.SampleRequested += async (s, e) =>
        {
            var deferral = e.Request.GetDeferral();
            try
            {
                if (await reader.WaitToReadAsync().ConfigureAwait(false) && reader.TryRead(out var f))
                {
                    var sample = MediaStreamSample.CreateFromBuffer(f.Bgra.AsBuffer(), f.Time);
                    sample.Duration = TimeSpan.FromSeconds(1.0 / 30);
                    e.Request.Sample = sample;
                }
                else e.Request.Sample = null;
            }
            finally { deferral.Complete(); }
        };

        var h264 = VideoEncodingProperties.CreateH264();
        h264.Width = (uint)width; h264.Height = (uint)height;
        h264.Bitrate = (uint)(width * height * 8);
        h264.FrameRate.Numerator = 30; h264.FrameRate.Denominator = 1;
        h264.PixelAspectRatio.Numerator = 1; h264.PixelAspectRatio.Denominator = 1;
        var profile = new MediaEncodingProfile
        {
            Container = new ContainerEncodingProperties { Subtype = MediaEncodingSubtypes.Mpeg4 },
            Video = h264,
            Audio = null,
        };

        var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(outPath)!);
        var file = await folder.CreateFileAsync(Path.GetFileName(outPath), CreationCollisionOption.ReplaceExisting);
        using var outStream = await file.OpenAsync(FileAccessMode.ReadWrite);

        var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
        var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(mss, outStream, profile);
        if (!prepared.CanTranscode)
            throw new InvalidOperationException($"Styled encode cannot start: {prepared.FailureReason}");
        await prepared.TranscodeAsync();
    }

    // ---- Overlays (ported from the macOS renderer) ----

    private static void DrawRipples(CanvasDrawingSession ds, RecordingMetadata meta, CameraViewport vp,
        double scale, Viewport view, double eventT, int outW)
    {
        foreach (var c in meta.Clicks)
        {
            double age = eventT - c.T;
            if (age < 0 || age > RippleDuration) continue;
            var p = vp.MapToOutput(c.X, c.Y, scale, view);
            if (p is null) continue;
            double prog = age / RippleDuration;
            float radius = (float)(outW * 0.05 * prog);
            if (radius < 1) continue;
            ds.DrawCircle((float)p.Value.X, (float)p.Value.Y, radius,
                Color.FromArgb((byte)(230 * (1 - prog)), 255, 255, 255), 3f);
        }
    }

    private static void DrawCursor(CanvasDrawingSession ds, CanvasBitmap cursor, FocusTimeline focus,
        CameraViewport vp, double scale, Viewport view, double eventT)
    {
        var cur = focus.CursorPoint(eventT);
        var p = vp.MapToOutput(cur.X, cur.Y, scale, view);
        if (p is not null) ds.DrawImage(cursor, (float)p.Value.X, (float)p.Value.Y);
    }

    private static CanvasBitmap MakeCursor(CanvasDevice device)
    {
        // A clean white arrow with a dark outline, tip at (0,0).
        const float k = 26f;
        using var rt = new CanvasRenderTarget(device, k * 0.7f, k, 96);
        using (var ds = rt.CreateDrawingSession())
        {
            ds.Clear(Colors.Transparent);
            using var path = new CanvasPathBuilder(device);
            (float x, float y)[] pts =
            {
                (0, 0), (0, 0.73f), (0.16f, 0.57f), (0.28f, 0.84f),
                (0.38f, 0.80f), (0.26f, 0.54f), (0.5f, 0.51f),
            };
            path.BeginFigure(0, 0);
            foreach (var (x, y) in pts[1..]) path.AddLine(x * k, y * k);
            path.EndFigure(CanvasFigureLoop.Closed);
            using var geo = CanvasGeometry.CreatePath(path);
            ds.FillGeometry(geo, Colors.White);
            ds.DrawGeometry(geo, Color.FromArgb(230, 0, 0, 0), 1.4f);
        }
        return CanvasBitmap.CreateFromBytes(device, rt.GetPixelBytes(),
            (int)rt.SizeInPixels.Width, (int)rt.SizeInPixels.Height, DirectXPixelFormatBgra);
    }

    private const Windows.Graphics.DirectX.DirectXPixelFormat DirectXPixelFormatBgra =
        Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized;

    private static void DrawBadge(CanvasDrawingSession ds, string label, int outW, int outH)
    {
        using var format = new CanvasTextFormat
        {
            FontSize = 34,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = CanvasHorizontalAlignment.Center,
        };
        using var layout = new CanvasTextLayout(ds, label, format, 600, 80);
        var b = layout.LayoutBounds;
        float padX = 24, padY = 12;
        float w = (float)(b.Width + padX * 2), h = (float)(b.Height + padY * 2);
        float x = (outW - w) / 2, y = outH - h - 90;
        ds.FillRoundedRectangle(x, y, w, h, 14, 14, Color.FromArgb(200, 20, 20, 20));
        ds.DrawTextLayout(layout, x + padX, y + padY, Colors.White);
    }

    private static int Even(int v) => v % 2 == 0 ? v : v - 1;
}
