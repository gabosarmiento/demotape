using System.Numerics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using System.Threading.Channels;
using DemoTape.Domain.Models;
using DemoTape.Domain.Rendering;
using DemoTape.Domain.Settings;
using Microsoft.Extensions.Logging;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Playback;
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
/// Frames are decoded sequentially via <c>MediaPlayer</c> frame-server mode (≈ real-time, far
/// faster than per-frame seeking), composited with Win2D, and encoded with the same
/// MediaStreamSource/MediaTranscoder path used by capture. This avoids a custom
/// <c>IBasicVideoEffect</c> (which can't be activated in an unpackaged app).
/// </summary>
public sealed class StyledVideoRenderer
{
    private const double Fps = 30;
    private const double RippleDuration = 0.5;

    private readonly ILogger<StyledVideoRenderer> _logger;

    public StyledVideoRenderer(ILogger<StyledVideoRenderer> logger) => _logger = logger;

    public async Task<string?> RenderAsync(string rawPath, string sidecarPath, string outPath,
        AppSettings settings, string? cameraPath = null, string? micPath = null, IProgress<double>? progress = null)
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
            double durationSec = vp.Duration.TotalSeconds > 0 ? vp.Duration.TotalSeconds : meta.Duration;

            var focus = new FocusTimeline(meta, maxZoom: settings.AutoZoom ? 2.0 : 1.0);
            var camera = new SpringCamera();
            double eventOffset = meta.EventTimeOffset ?? 0;

            // Region mode: crop to the selected region and frame it on a padded background.
            bool framed = settings.UseRegion && settings.RegionW > 0 && settings.RegionH > 0;
            var srcRegion = framed
                ? new Rect(settings.RegionX * W, settings.RegionY * H, settings.RegionW * W, settings.RegionH * H)
                : new Rect(0, 0, W, H);
            int pad = framed ? 48 : 0;
            int contentW = Even((int)srcRegion.Width);
            int contentH = Even((int)srcRegion.Height);
            int outW = Even(contentW + pad * 2);
            int outH = Even(contentH + pad * 2);
            var viewport = new CameraViewport(outW, outH, pad);

            using var device = new CanvasDevice();
            using var frameSurface = new CanvasRenderTarget(device, W, H, 96); // MediaPlayer copies each frame here
            using var frameRT = new CanvasRenderTarget(device, outW, outH, 96);
            using var compRT = new CanvasRenderTarget(device, outW, outH, 96);
            using var flipRT = new CanvasRenderTarget(device, outW, outH, 96);
            using var cursorImg = MakeCursor(device);
            using var background = framed ? LoadBackground(device, settings.BackgroundFile, outW, outH) : null;
            using var contentClip = framed
                ? CanvasGeometry.CreateRoundedRectangle(device, pad, pad, contentW, contentH, 20, 20)
                : null;

            // Optional webcam PiP: a second frame-server player kept roughly in sync with the screen.
            bool useCam = settings.CaptureWebcam && cameraPath is not null && File.Exists(cameraPath);
            MediaPlayer? camPlayer = null;
            CanvasRenderTarget? camSurface = null;
            // One lock serializes ALL Win2D device access: the two frame-server callbacks
            // (screen + webcam) run on different threads and the device is not thread-safe.
            var deviceLock = new object();
            bool camHasFrame = false;
            if (useCam)
            {
                var camFile = await StorageFile.GetFileFromPathAsync(cameraPath!);
                var camVp = await camFile.Properties.GetVideoPropertiesAsync();
                int cw = camVp.Width > 0 ? (int)camVp.Width : 1280;
                int ch = camVp.Height > 0 ? (int)camVp.Height : 720;
                camSurface = new CanvasRenderTarget(device, cw, ch, 96);
                camPlayer = new MediaPlayer { IsMuted = true, IsVideoFrameServerEnabled = true, IsLoopingEnabled = false };
                var camOpened = new TaskCompletionSource<bool>();
                camPlayer.MediaOpened += (_, _) => camOpened.TrySetResult(true);
                camPlayer.MediaFailed += (_, _) => camOpened.TrySetResult(true);
                camPlayer.VideoFrameAvailable += (_, _) =>
                {
                    try { lock (deviceLock) { camPlayer.CopyFrameToVideoSurface(camSurface); camHasFrame = true; } }
                    catch { /* ignore */ }
                };
                camPlayer.Source = MediaSource.CreateFromStorageFile(camFile);
                await camOpened.Task;
            }

            var channel = Channel.CreateBounded<(byte[] Bgra, TimeSpan Time)>(
                new BoundedChannelOptions(90) { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true });
            var encodeTask = EncodeAsync(channel.Reader, outW, outH, outPath);

            // Sequential decode via MediaPlayer frame-server mode (≈ real-time, no per-frame seeking).
            var player = new MediaPlayer { IsMuted = true, IsVideoFrameServerEnabled = true, IsLoopingEnabled = false };
            var opened = new TaskCompletionSource<bool>();
            var ended = new TaskCompletionSource<bool>();
            player.MediaOpened += (_, _) => opened.TrySetResult(true);
            player.MediaFailed += (_, a) => { opened.TrySetException(new Exception(a.ErrorMessage)); ended.TrySetResult(true); };
            player.MediaEnded += (_, _) => ended.TrySetResult(true);

            double lastT = -1;
            int frameCount = 0;
            player.VideoFrameAvailable += (_, _) =>
            {
                try
                {
                  lock (deviceLock)
                  {
                    player.CopyFrameToVideoSurface(frameSurface);
                    double t = player.PlaybackSession.Position.TotalSeconds;
                    double eventT = t + eventOffset;
                    double dt = lastT < 0 ? 1.0 / Fps : Math.Clamp(t - lastT, 1.0 / 240, 1.0 / 20);
                    lastT = t;

                    var targetFocus = focus.Target(eventT);
                    camera.Step(targetFocus, dt);
                    var view = viewport.ComputeViewport(camera.Scale, camera.CenterX, camera.CenterY);

                    ICanvasImage zoomSource;
                    if (framed)
                    {
                        using (var ds = frameRT.CreateDrawingSession())
                        {
                            ds.Clear(Colors.Black);
                            if (background is not null) ds.DrawImage(background);
                            using (ds.CreateLayer(1f, contentClip))
                                ds.DrawImage(frameSurface, new Rect(pad, pad, contentW, contentH), srcRegion);
                        }
                        zoomSource = frameRT;
                    }
                    else
                    {
                        zoomSource = frameSurface; // full frame == output size
                    }

                    using (var ds = compRT.CreateDrawingSession())
                    {
                        ds.Clear(Colors.Black);
                        ds.DrawImage(zoomSource,
                            new Rect(0, 0, outW, outH),
                            new Rect(view.OffsetX, view.OffsetY, view.Width, view.Height));
                        DrawRipples(ds, meta, viewport, camera.Scale, view, eventT, outW);
                        DrawCursor(ds, cursorImg, focus, viewport, camera.Scale, view, eventT);
                        if (settings.ShowShortcutBadges)
                        {
                            var label = focus.ShortcutBadge(eventT);
                            if (label is not null) DrawBadge(ds, label, outW, outH);
                        }
                        // Webcam PiP — fixed position/size (does not zoom).
                        if (useCam && camHasFrame && camSurface is not null)
                            DrawWebcam(ds, camSurface, settings, outW, outH);
                    }

                    using (var ds = flipRT.CreateDrawingSession())
                    {
                        ds.Transform = Matrix3x2.CreateScale(1, -1) * Matrix3x2.CreateTranslation(0, outH);
                        ds.DrawImage(compRT);
                    }

                    channel.Writer.TryWrite((flipRT.GetPixelBytes(), TimeSpan.FromSeconds(t)));
                    frameCount++;
                    if (durationSec > 0) progress?.Report(Math.Clamp(t / durationSec, 0, 1));
                  } // lock (deviceLock)
                }
                catch (Exception ex) { _logger.LogWarning(ex, "Styled frame skipped"); }
            };

            player.Source = MediaSource.CreateFromStorageFile(rawFile);
            await opened.Task;
            camPlayer?.Play(); // start webcam roughly in sync with the screen
            player.Play();
            await ended.Task;
            await Task.Delay(150); // let the final frames enqueue
            channel.Writer.Complete();
            await encodeTask;
            player.Dispose();
            camPlayer?.Dispose();
            camSurface?.Dispose();

            // Mux the microphone narration into the (silent) styled video.
            if (micPath is not null && File.Exists(micPath))
            {
                try { await MuxAudioAsync(outPath, micPath, outW, outH); }
                catch (Exception ex) { _logger.LogWarning(ex, "Audio mux failed; keeping silent video"); }
            }

            _logger.LogInformation("Styled render complete ({Frames} frames) -> {Name}", frameCount, Path.GetFileName(outPath));
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
        // A clean white arrow with a dark outline, tip at (0,0). Drawn at 2x for visibility.
        const float k = 52f;
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

    /// <summary>Muxes a microphone track into the styled (silent) video via MediaComposition.</summary>
    private async Task MuxAudioAsync(string videoPath, string micPath, int outW, int outH)
    {
        var vFile = await StorageFile.GetFileFromPathAsync(videoPath);
        var clip = await Windows.Media.Editing.MediaClip.CreateFromFileAsync(vFile);
        var comp = new Windows.Media.Editing.MediaComposition();
        comp.Clips.Add(clip);

        var aFile = await StorageFile.GetFileFromPathAsync(micPath);
        var track = await Windows.Media.Editing.BackgroundAudioTrack.CreateFromFileAsync(aFile);
        comp.BackgroundAudioTracks.Add(track);

        var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(videoPath)!);
        var tmp = await folder.CreateFileAsync(Path.GetFileNameWithoutExtension(videoPath) + ".mux.mp4",
            CreationCollisionOption.ReplaceExisting);

        var h264 = VideoEncodingProperties.CreateH264();
        h264.Width = (uint)outW; h264.Height = (uint)outH;
        h264.Bitrate = (uint)(outW * outH * 8);
        h264.FrameRate.Numerator = 30; h264.FrameRate.Denominator = 1;
        var profile = new MediaEncodingProfile
        {
            Container = new ContainerEncodingProperties { Subtype = MediaEncodingSubtypes.Mpeg4 },
            Video = h264,
            Audio = AudioEncodingProperties.CreateAac(48000, 2, 128000),
        };

        var reason = await comp.RenderToFileAsync(tmp, Windows.Media.Editing.MediaTrimmingPreference.Fast, profile);
        if (reason != TranscodeFailureReason.None)
        {
            _logger.LogWarning("Audio mux render failed: {Reason}", reason);
            try { File.Delete(tmp.Path); } catch { }
            return;
        }
        // Replace the silent styled video with the muxed one.
        File.Delete(videoPath);
        File.Move(tmp.Path, videoPath);
        _logger.LogInformation("Muxed microphone audio into {Name}", Path.GetFileName(videoPath));
    }

    private static void DrawWebcam(CanvasDrawingSession ds, CanvasRenderTarget cam, AppSettings s, int outW, int outH)
    {
        double diameter = s.WebcamSize * outW;
        if (diameter < 8) return;
        float r = (float)(diameter / 2);
        var center = new Vector2((float)(s.WebcamPositionX * outW), (float)(s.WebcamPositionY * outH));

        double zoom = Math.Max(1, s.WebcamZoom);
        double camW = cam.Size.Width, camH = cam.Size.Height;
        double scale = Math.Max(diameter / camW, diameter / camH) * zoom;
        double dw = camW * scale, dh = camH * scale;
        var dst = new Rect(center.X - dw / 2, center.Y - dh / 2, dw, dh);

        using (ds.CreateLayer(1f, CanvasGeometry.CreateCircle(ds.Device, center, r)))
        {
            ds.Transform = Matrix3x2.CreateScale(-1f, 1f, center); // mirror (selfie view)
            ds.DrawImage(cam, dst);
            ds.Transform = Matrix3x2.Identity;
        }
        ds.DrawCircle(center, r, Color.FromArgb(230, 255, 255, 255), 3f);
    }

    private static CanvasRenderTarget LoadBackground(CanvasDevice device, string bgFile, int outW, int outH)
    {
        var rt = new CanvasRenderTarget(device, outW, outH, 96);
        using var ds = rt.CreateDrawingSession();
        var path = ResolveBackgroundPath(bgFile);
        if (path is not null)
        {
            try
            {
                using var img = CanvasBitmap.LoadAsync(device, path).AsTask().GetAwaiter().GetResult();
                double s = Math.Max(outW / img.Size.Width, outH / img.Size.Height);
                double dw = img.Size.Width * s, dh = img.Size.Height * s;
                ds.DrawImage(img, new Rect((outW - dw) / 2, (outH - dh) / 2, dw, dh));
                return rt;
            }
            catch { /* fall through to gradient */ }
        }
        using var brush = new CanvasLinearGradientBrush(device,
            Color.FromArgb(255, 41, 46, 77), Color.FromArgb(255, 15, 18, 31))
        {
            StartPoint = new Vector2(0, 0),
            EndPoint = new Vector2(0, outH),
        };
        ds.FillRectangle(0, 0, outW, outH, brush);
        return rt;
    }

    private static string? ResolveBackgroundPath(string bgFile)
    {
        if (string.IsNullOrWhiteSpace(bgFile)) return null;
        if (Path.IsPathRooted(bgFile) && File.Exists(bgFile)) return bgFile;
        var bundled = Path.Combine(AppContext.BaseDirectory, "Assets", "Backgrounds", bgFile);
        return File.Exists(bundled) ? bundled : null;
    }

    private static int Even(int v) => v % 2 == 0 ? v : v - 1;
}
