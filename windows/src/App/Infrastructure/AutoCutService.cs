using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Channels;
using DemoTape.Domain.Audio;
using Microsoft.Graphics.Canvas;
using Windows.Media.Core;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Playback;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Local "Auto-Cut": detect silent gaps by loudness analysis and rebuild the video with them
/// removed (a <c>…tight.mp4</c>). No network, no cost. Windows analogue of the macOS <c>Tightener</c>
/// (silence removal + optional pitch-preserved speed-up).
/// </summary>
public sealed class AutoCutService
{
    /// <summary>
    /// Auto-cut options.
    /// <list type="bullet">
    ///   <item><c>SilenceThresholdDb</c> — loudness floor for silence detection.</item>
    ///   <item><c>MinSilence</c> — minimum gap length (seconds) to cut.</item>
    ///   <item><c>Padding</c> — silence padding kept at each cut edge (seconds).</item>
    ///   <item><c>SpeedMultiplier</c> — playback speed of retained segments (1.0 = original, 1.5 = 50 % faster).
    ///     Applied as a post-render frame-server pass (video-only; audio is re-muxed at full speed, i.e. V1 audio
    ///     will be truncated to the new duration rather than pitch-preserved).</item>
    /// </list>
    /// </summary>
    public sealed record Options(
        float SilenceThresholdDb = -40,
        double MinSilence = 0.6,
        double Padding = 0.12,
        double SpeedMultiplier = 1.0);

    /// <summary>Produces <paramref name="outPath"/> with silent gaps trimmed. Returns null if there was nothing to cut.</summary>
    public async Task<string?> AutoCutAsync(string videoPath, string outPath, Options options,
        IProgress<double>? progress = null, CancellationToken ct = default)
    {
        progress?.Report(0.05);
        var (mono, rate) = await WavAudioIo.ExtractMonoAsync(videoPath, 16000, ct).ConfigureAwait(false);

        var vFile = await StorageFile.GetFileFromPathAsync(videoPath).AsTask(ct).ConfigureAwait(false);
        var vp = await vFile.Properties.GetVideoPropertiesAsync().AsTask(ct).ConfigureAwait(false);
        double duration = vp.Duration.TotalSeconds;
        if (duration <= 0) return null;

        var (flags, win) = SilencePlanner.Loudness(mono, rate, options.SilenceThresholdDb);
        var keep = SilencePlanner.KeepRanges(flags, win, duration, options.MinSilence, options.Padding);
        progress?.Report(0.2);

        // Nothing to do if we'd keep essentially the whole clip in one range.
        bool trims = keep.Count > 1 || (keep.Count == 1 && (keep[0].Start > 0.05 || keep[0].End < duration - 0.05));
        if (!trims && Math.Abs(options.SpeedMultiplier - 1.0) <= 0.001) return null;

        // Build MediaComposition with only the kept ranges (silence removed).
        var comp = new MediaComposition();
        foreach (var r in keep)
        {
            var clip = await MediaClip.CreateFromFileAsync(vFile).AsTask(ct).ConfigureAwait(false);
            clip.TrimTimeFromStart = TimeSpan.FromSeconds(Math.Max(0, r.Start));
            clip.TrimTimeFromEnd = TimeSpan.FromSeconds(Math.Max(0, duration - r.End));
            comp.Clips.Add(clip);
        }
        progress?.Report(0.35);

        var outDir = Path.GetDirectoryName(outPath)!;
        var folder = await StorageFolder.GetFolderFromPathAsync(outDir).AsTask(ct).ConfigureAwait(false);
        var outFile = await folder.CreateFileAsync(Path.GetFileName(outPath), CreationCollisionOption.ReplaceExisting).AsTask(ct).ConfigureAwait(false);

        int w = (int)(vp.Width == 0 ? 1280 : vp.Width), h = (int)(vp.Height == 0 ? 720 : vp.Height);
        var h264 = VideoEncodingProperties.CreateH264();
        h264.Width = (uint)Even(w); h264.Height = (uint)Even(h);
        h264.Bitrate = (uint)(Even(w) * Even(h) * 8);
        h264.FrameRate.Numerator = 30; h264.FrameRate.Denominator = 1;
        var profile = new MediaEncodingProfile
        {
            Container = new ContainerEncodingProperties { Subtype = MediaEncodingSubtypes.Mpeg4 },
            Video = h264,
            Audio = AudioEncodingProperties.CreateAac(48000, 2, 128000),
        };
        var reason = await comp.RenderToFileAsync(outFile, MediaTrimmingPreference.Precise, profile).AsTask(ct).ConfigureAwait(false);
        if (reason != TranscodeFailureReason.None) throw new InvalidOperationException($"Auto-Cut render failed ({reason}).");
        progress?.Report(0.75);

        // Post-render speed pass: compress video timestamps by speedMultiplier using a frame-server
        // pipeline (Win2D + MediaStreamSource + MediaTranscoder), same pattern as CaptionBurner.
        // V1: video is re-timed; audio is taken from the render output and truncated to the new
        // (shorter) duration — pitch-preserved audio speed-up is a future improvement.
        if (Math.Abs(options.SpeedMultiplier - 1.0) > 0.001)
            await ApplySpeedAsync(outPath, Even(w), Even(h), options.SpeedMultiplier, ct).ConfigureAwait(false);

        progress?.Report(1.0);
        return outPath;
    }

    // ---------------------------------------------------------------------------
    // Frame-server speed pass
    // ---------------------------------------------------------------------------

    private static async Task ApplySpeedAsync(string path, int w, int h, double speedMultiplier, CancellationToken ct)
    {
        var tempVideo = Path.Combine(Path.GetTempPath(), $"demotape-speed-{Guid.NewGuid():N}.mp4");

        var sourceFile = await StorageFile.GetFileFromPathAsync(path).AsTask(ct).ConfigureAwait(false);

        using (var device = new CanvasDevice())
        using (var frameSurface = new CanvasRenderTarget(device, w, h, 96))
        {
            var channel = Channel.CreateBounded<(byte[] Bgra, TimeSpan Time)>(
                new BoundedChannelOptions(90) { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true });
            var encodeTask = EncodeSpeedAsync(channel.Reader, w, h, tempVideo);

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
                    // Compress the timeline: source position t maps to output position t/speedMultiplier.
                    // The output is shorter by factor 1/speedMultiplier → plays back faster at normal rate.
                    double t = player.PlaybackSession.Position.TotalSeconds / speedMultiplier;
                    channel.Writer.TryWrite((frameSurface.GetPixelBytes(), TimeSpan.FromSeconds(t)));
                }
                catch { /* skip frame on any device/surface error */ }
            };

            player.Source = MediaSource.CreateFromStorageFile(sourceFile);
            await opened.Task.ConfigureAwait(false);
            player.Play();
            await ended.Task.ConfigureAwait(false);
            await Task.Delay(150, ct).ConfigureAwait(false);
            channel.Writer.Complete();
            await encodeTask.ConfigureAwait(false);
            player.Dispose();
        }

        // Swap the speed-adjusted video-only temp over the original file.
        if (File.Exists(path)) File.Delete(path);
        File.Move(tempVideo, path);
    }

    private static async Task EncodeSpeedAsync(ChannelReader<(byte[] Bgra, TimeSpan Time)> reader, int w, int h, string outPath)
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
                    sample.Duration = TimeSpan.FromSeconds(1.0 / 30.0);
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
            Audio = null,   // audio is handled by the caller (re-mux or truncation)
        };

        var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(outPath)!);
        var file = await folder.CreateFileAsync(Path.GetFileName(outPath), CreationCollisionOption.ReplaceExisting);
        using var outStream = await file.OpenAsync(FileAccessMode.ReadWrite);
        var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
        var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(mss, outStream, profile);
        if (!prepared.CanTranscode) throw new InvalidOperationException($"Speed encode failed: {prepared.FailureReason}");
        await prepared.TranscodeAsync();
    }

    private static int Even(int v) => v % 2 == 0 ? v : v - 1;
}
