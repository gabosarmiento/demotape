using DemoTape.Domain.Audio;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Local "Auto-Cut": detect silent gaps by loudness analysis and rebuild the video with them
/// removed (a <c>…tight.mp4</c>). No network, no cost. Windows analogue of the macOS <c>Tightener</c>
/// (silence removal; pitch-preserved speed-up is a later addition).
/// </summary>
public sealed class AutoCutService
{
    public sealed record Options(float SilenceThresholdDb = -40, double MinSilence = 0.6, double Padding = 0.12);

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
        if (!trims) return null;

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
        progress?.Report(1.0);
        return outPath;
    }

    private static int Even(int v) => v % 2 == 0 ? v : v - 1;
}
