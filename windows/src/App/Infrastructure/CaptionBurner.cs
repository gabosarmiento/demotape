using System.Numerics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Channels;
using DemoTape.Domain.Ai;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Playback;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.UI;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Burns caption cues into a video: decodes frames (MediaPlayer frame-server), draws the active cue
/// near the bottom with Win2D, encodes H.264, then remuxes the original audio. Same pipeline family
/// as <see cref="StyledVideoRenderer"/>.
/// </summary>
public sealed class CaptionBurner
{
    private const double Fps = 30;

    /// <summary>Burns <paramref name="cues"/> into <paramref name="sourcePath"/> → <paramref name="outPath"/>.</summary>
    public async Task<string> BurnAsync(string sourcePath, IReadOnlyList<CaptionCue> cues, string outPath,
        IProgress<double>? progress = null, CancellationToken ct = default)
    {
        var sourceFile = await StorageFile.GetFileFromPathAsync(sourcePath).AsTask(ct);
        var vp = await sourceFile.Properties.GetVideoPropertiesAsync().AsTask(ct);
        int w = Even((int)(vp.Width == 0 ? 1280 : vp.Width));
        int h = Even((int)(vp.Height == 0 ? 720 : vp.Height));
        double duration = vp.Duration.TotalSeconds;

        // Render captions onto a video-only temp file first.
        var tempVideo = Path.Combine(Path.GetTempPath(), $"demotape-cap-{Guid.NewGuid():N}.mp4");

        using (var device = new CanvasDevice())
        using (var frameSurface = new CanvasRenderTarget(device, w, h, 96))
        using (var compRT = new CanvasRenderTarget(device, w, h, 96))
        using (var flipRT = new CanvasRenderTarget(device, w, h, 96))
        {
            var channel = Channel.CreateBounded<(byte[] Bgra, TimeSpan Time)>(
                new BoundedChannelOptions(90) { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true });
            var encodeTask = EncodeAsync(channel.Reader, w, h, tempVideo);

            var player = new MediaPlayer { IsMuted = true, IsVideoFrameServerEnabled = true, IsLoopingEnabled = false };
            var opened = new TaskCompletionSource<bool>();
            var ended = new TaskCompletionSource<bool>();
            player.MediaOpened += (_, _) => opened.TrySetResult(true);
            player.MediaFailed += (_, a) => { opened.TrySetException(new Exception(a.ErrorMessage)); ended.TrySetResult(true); };
            player.MediaEnded += (_, _) => ended.TrySetResult(true);

            player.VideoFrameAvailable += (_, _) =>
            {
                try
                {
                    player.CopyFrameToVideoSurface(frameSurface);
                    double t = player.PlaybackSession.Position.TotalSeconds;
                    using (var ds = compRT.CreateDrawingSession())
                    {
                        ds.DrawImage(frameSurface);
                        DrawCaption(ds, ActiveCue(cues, t), w, h);
                    }
                    using (var ds = flipRT.CreateDrawingSession())
                    {
                        ds.Transform = Matrix3x2.CreateScale(1, -1) * Matrix3x2.CreateTranslation(0, h);
                        ds.DrawImage(compRT);
                    }
                    channel.Writer.TryWrite((flipRT.GetPixelBytes(), TimeSpan.FromSeconds(t)));
                    if (duration > 0) progress?.Report(Math.Clamp(t / duration, 0, 1));
                }
                catch { /* skip frame */ }
            };

            player.Source = MediaSource.CreateFromStorageFile(sourceFile);
            await opened.Task;
            player.Play();
            await ended.Task;
            await Task.Delay(150);
            channel.Writer.Complete();
            await encodeTask;
            player.Dispose();
        }

        // Remux the original audio back over the captioned video (best-effort — keep video if it fails).
        try
        {
            var audio = await AiMedia.ExtractAudioAsync(sourcePath, ct);
            try { await AiMedia.MuxNarrationAsync(tempVideo, audio, outPath, w, h, ct); }
            finally { TryDelete(audio); }
            TryDelete(tempVideo);
        }
        catch
        {
            // No audio (or mux failed): the captioned video-only file becomes the output.
            if (File.Exists(outPath)) TryDelete(outPath);
            File.Move(tempVideo, outPath);
        }
        return outPath;
    }

    private static CaptionCue? ActiveCue(IReadOnlyList<CaptionCue> cues, double t)
    {
        foreach (var c in cues)
        {
            if (c.End <= 0 && c.Start <= 0) return c;              // single whole-clip cue
            if (t >= c.Start && (t <= c.End || c.End <= 0)) return c;
        }
        return null;
    }

    private static void DrawCaption(CanvasDrawingSession ds, CaptionCue? cue, int w, int h)
    {
        if (cue is null || string.IsNullOrWhiteSpace(cue.Value.Text)) return;
        float fontSize = MathF.Max(18, h * 0.045f);
        using var format = new CanvasTextFormat
        {
            FontSize = fontSize,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = CanvasHorizontalAlignment.Center,
            WordWrapping = CanvasWordWrapping.Wrap,
        };
        float maxW = w * 0.86f;
        using var layout = new CanvasTextLayout(ds, cue.Value.Text, format, maxW, h * 0.4f);
        var b = layout.LayoutBounds;
        float padX = 18, padY = 10;
        float boxW = (float)b.Width + padX * 2;
        float boxH = (float)b.Height + padY * 2;
        float x = (w - boxW) / 2f;
        float y = h - boxH - h * 0.06f;
        ds.FillRoundedRectangle(x, y, boxW, boxH, 10, 10, Color.FromArgb(170, 0, 0, 0));
        ds.DrawTextLayout(layout, x + padX, y + padY, Colors.White);
    }

    private static async Task EncodeAsync(ChannelReader<(byte[] Bgra, TimeSpan Time)> reader, int w, int h, string outPath)
    {
        var inProps = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)w, (uint)h);
        inProps.FrameRate.Numerator = 30; inProps.FrameRate.Denominator = 1;
        inProps.PixelAspectRatio.Numerator = 1; inProps.PixelAspectRatio.Denominator = 1;
        var mss = new MediaStreamSource(new VideoStreamDescriptor(inProps));
        mss.SampleRequested += async (_, e) =>
        {
            var deferral = e.Request.GetDeferral();
            try
            {
                if (await reader.WaitToReadAsync().ConfigureAwait(false) && reader.TryRead(out var f))
                {
                    var sample = MediaStreamSample.CreateFromBuffer(f.Bgra.AsBuffer(), f.Time);
                    sample.Duration = TimeSpan.FromSeconds(1.0 / Fps);
                    e.Request.Sample = sample;
                }
                else e.Request.Sample = null;
            }
            finally { deferral.Complete(); }
        };

        var h264 = VideoEncodingProperties.CreateH264();
        h264.Width = (uint)w; h264.Height = (uint)h;
        h264.Bitrate = (uint)(w * h * 8);
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
        if (!prepared.CanTranscode) throw new InvalidOperationException($"Caption encode failed: {prepared.FailureReason}");
        await prepared.TranscodeAsync();
    }

    private static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }
    private static int Even(int v) => v % 2 == 0 ? v : v - 1;
}
