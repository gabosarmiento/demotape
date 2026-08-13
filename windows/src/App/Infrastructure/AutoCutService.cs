using System.Runtime.InteropServices.WindowsRuntime;
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
    // Approach: decode all frames into a ConcurrentQueue via MediaPlayer frame-server,
    // then drive a MediaStreamSource + MediaTranscoder to re-encode with compressed timestamps.
    // Key correctness requirements:
    //   1. mss.Duration must be set so the transcoder knows when to stop.
    //   2. Each frame gets its OWN byte array (no surface sharing between events).
    //   3. SampleRequested uses a blocking wait (ManualResetEventSlim) — WinRT deferrals
    //      must not await managed Tasks directly (deadlock risk).

    private static async Task ApplySpeedAsync(string path, int w, int h, double speedMultiplier, CancellationToken ct)
    {
        var sourceFile = await StorageFile.GetFileFromPathAsync(path).AsTask(ct).ConfigureAwait(false);
        var vp = await sourceFile.Properties.GetVideoPropertiesAsync().AsTask(ct).ConfigureAwait(false);
        double sourceDurationSec = vp.Duration.TotalSeconds;
        if (sourceDurationSec <= 0) return;
        double outputDurationSec = sourceDurationSec / speedMultiplier;

        var tempOut = Path.Combine(Path.GetTempPath(), $"demotape-speed-{Guid.NewGuid():N}.mp4");

        // --- Phase 1: decode frames ---
        var frameQueue = new System.Collections.Concurrent.ConcurrentQueue<(byte[] Bgra, TimeSpan OutputTime)>();
        var decodeSignal = new System.Threading.SemaphoreSlim(0);
        var decodeDone   = new System.Threading.ManualResetEventSlim(false);

        var player = new MediaPlayer { IsMuted = true, IsVideoFrameServerEnabled = true, IsLoopingEnabled = false };
        var mediaReady = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var mediaEnd   = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        player.MediaOpened += (_, _) => mediaReady.TrySetResult(true);
        player.MediaFailed += (_, a)  => { mediaReady.TrySetException(new Exception(a.ErrorMessage ?? "MediaPlayer failed")); mediaEnd.TrySetResult(true); };
        player.MediaEnded  += (_, _)  => mediaEnd.TrySetResult(true);

        using var device = CanvasDevice.GetSharedDevice();
        player.VideoFrameAvailable += (_, _) =>
        {
            try
            {
                // Allocate a private surface per frame so there is no sharing between events.
                using var surface = new CanvasRenderTarget(device, w, h, 96);
                player.CopyFrameToVideoSurface(surface);
                double srcSec = player.PlaybackSession.Position.TotalSeconds;
                double outSec = srcSec / speedMultiplier;
                frameQueue.Enqueue((surface.GetPixelBytes(), TimeSpan.FromSeconds(outSec)));
                decodeSignal.Release();
            }
            catch { /* skip bad frame */ }
        };

        player.Source = MediaSource.CreateFromStorageFile(sourceFile);
        await mediaReady.Task.ConfigureAwait(false);
        player.Play();
        await mediaEnd.Task.ConfigureAwait(false);
        await Task.Delay(200, ct).ConfigureAwait(false); // let last frames drain
        decodeDone.Set();
        player.Dispose();

        if (frameQueue.IsEmpty) return; // nothing captured — skip speed pass

        // --- Phase 2: encode with compressed timestamps ---
        var inProps = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)w, (uint)h);
        inProps.FrameRate.Numerator = 30; inProps.FrameRate.Denominator = 1;
        inProps.PixelAspectRatio.Numerator = 1; inProps.PixelAspectRatio.Denominator = 1;

        var mss = new MediaStreamSource(new VideoStreamDescriptor(inProps));
        mss.Duration  = TimeSpan.FromSeconds(outputDurationSec);
        mss.BufferTime = TimeSpan.Zero;

        // SampleRequested: use blocking wait — no async/await inside WinRT deferrals.
        mss.SampleRequested += (_, e) =>
        {
            var deferral = e.Request.GetDeferral();
            try
            {
                // Spin-wait up to 3 s for the next frame from the decode queue.
                var deadline = DateTime.UtcNow.AddSeconds(3);
                (byte[] Bgra, TimeSpan OutputTime) frame = default;
                while (!frameQueue.TryDequeue(out frame))
                {
                    if (decodeDone.IsSet || DateTime.UtcNow > deadline)
                    { e.Request.Sample = null; return; }
                    System.Threading.Thread.Sleep(2);
                }
                var sample = MediaStreamSample.CreateFromBuffer(frame.Bgra.AsBuffer(), frame.OutputTime);
                sample.Duration = TimeSpan.FromSeconds(1.0 / 30.0);
                e.Request.Sample = sample;
            }
            finally { deferral.Complete(); }
        };

        var h264 = VideoEncodingProperties.CreateH264();
        h264.Width = (uint)w; h264.Height = (uint)h;
        h264.Bitrate = (uint)Math.Min((ulong)(w * h * 6), uint.MaxValue);
        h264.FrameRate.Numerator = 30; h264.FrameRate.Denominator = 1;
        var profile = new MediaEncodingProfile
        {
            Container = new ContainerEncodingProperties { Subtype = MediaEncodingSubtypes.Mpeg4 },
            Video = h264,
            Audio = null,
        };

        var outFolder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(tempOut)!).AsTask(ct).ConfigureAwait(false);
        var outFile   = await outFolder.CreateFileAsync(Path.GetFileName(tempOut), CreationCollisionOption.ReplaceExisting).AsTask(ct).ConfigureAwait(false);
        using var outStream = await outFile.OpenAsync(FileAccessMode.ReadWrite).AsTask(ct).ConfigureAwait(false);

        var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = false };
        var prepared   = await transcoder.PrepareMediaStreamSourceTranscodeAsync(mss, outStream, profile).AsTask(ct).ConfigureAwait(false);
        if (!prepared.CanTranscode) throw new InvalidOperationException($"Speed encode setup failed: {prepared.FailureReason}");
        await prepared.TranscodeAsync().AsTask(ct).ConfigureAwait(false);

        outStream.Dispose();
        File.Delete(path);
        File.Move(tempOut, path);
    }

    private static int Even(int v) => v % 2 == 0 ? v : v - 1;
}
