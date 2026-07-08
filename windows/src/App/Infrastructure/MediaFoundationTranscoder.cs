using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Publishing;
using Microsoft.Extensions.Logging;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.Streams;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Downscales a styled MP4 into a web-ready tier using the native Windows
/// <see cref="MediaTranscoder"/> (Media Foundation) — the Windows analogue of the macOS
/// <c>AVAssetReader</c>/<c>AVAssetWriter</c> pipeline. H.264 + AAC MP4 with a target bitrate
/// per tier from <see cref="WebPublishPlanner.BitrateKbps"/>. No third-party dependencies.
/// </summary>
public sealed class MediaFoundationTranscoder : IVideoTranscoder
{
    private readonly ILogger<MediaFoundationTranscoder> _logger;

    public MediaFoundationTranscoder(ILogger<MediaFoundationTranscoder> logger) => _logger = logger;

    public async Task TranscodeAsync(string inputPath, string outputPath, int height,
        IProgress<double>? progress = null, CancellationToken ct = default)
    {
        var input = await StorageFile.GetFileFromPathAsync(inputPath).AsTask(ct).ConfigureAwait(false);

        // Compute a width that preserves aspect and stays even; cap at 1280 wide.
        var props = await input.Properties.GetVideoPropertiesAsync().AsTask(ct).ConfigureAwait(false);
        uint srcW = props.Width == 0 ? 1920 : props.Width;
        uint srcH = props.Height == 0 ? 1080 : props.Height;
        double aspect = (double)srcW / srcH;
        uint outH = Even((uint)height);
        uint outW = Even((uint)Math.Round(outH * aspect));
        if (outW > 1280) { double k = 1280.0 / outW; outW = Even((uint)(outW * k)); outH = Even((uint)(outH * k)); }

        int vKbps = WebPublishPlanner.BitrateKbps.TryGetValue(height, out var b) ? b : 1400;

        var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD720p);
        profile.Video = VideoEncodingProperties.CreateH264();
        profile.Video.Width = outW;
        profile.Video.Height = outH;
        profile.Video.Bitrate = (uint)(vKbps * 1000);
        profile.Audio = AudioEncodingProperties.CreateAac(48000, 2, 128000);

        var outDir = Path.GetDirectoryName(outputPath)!;
        var folder = await StorageFolder.GetFolderFromPathAsync(outDir).AsTask(ct).ConfigureAwait(false);
        var output = await folder.CreateFileAsync(Path.GetFileName(outputPath), CreationCollisionOption.ReplaceExisting)
            .AsTask(ct).ConfigureAwait(false);

        var transcoder = new MediaTranscoder { AlwaysReencode = true };
        // faststart equivalent: MediaTranscoder writes a web-optimized MP4 (moov placement).
        var prepared = await transcoder.PrepareFileTranscodeAsync(input, output, profile).AsTask(ct).ConfigureAwait(false);
        if (!prepared.CanTranscode)
            throw new InvalidOperationException($"Cannot transcode to {height}p: {prepared.FailureReason}");

        var op = prepared.TranscodeAsync();
        op.Progress = (_, pct) => progress?.Report(Math.Clamp(pct / 100.0, 0, 1));
        await op.AsTask(ct).ConfigureAwait(false);
        _logger.LogInformation("Transcoded {W}x{H} @ {Kbps}kbps -> {Name}", outW, outH, vKbps, Path.GetFileName(outputPath));
    }

    public async Task SavePosterAsync(string inputPath, string outputPath, int maxHeight, CancellationToken ct = default)
    {
        var input = await StorageFile.GetFileFromPathAsync(inputPath).AsTask(ct).ConfigureAwait(false);
        var clip = await MediaClip.CreateFromFileAsync(input).AsTask(ct).ConfigureAwait(false);
        var composition = new MediaComposition();
        composition.Clips.Add(clip);

        // Grab a representative frame at ~15% in (matching the macOS poster time).
        var at = TimeSpan.FromSeconds(Math.Min(1.0, composition.Duration.TotalSeconds * 0.15));
        var thumb = await composition.GetThumbnailAsync(
            at, 0, (int)maxHeight, VideoFramePrecision.NearestFrame).AsTask(ct).ConfigureAwait(false);

        var outDir = Path.GetDirectoryName(outputPath)!;
        var folder = await StorageFolder.GetFolderFromPathAsync(outDir).AsTask(ct).ConfigureAwait(false);
        var posterFile = await folder.CreateFileAsync(Path.GetFileName(outputPath), CreationCollisionOption.ReplaceExisting)
            .AsTask(ct).ConfigureAwait(false);

        using var outStream = await posterFile.OpenAsync(FileAccessMode.ReadWrite).AsTask(ct).ConfigureAwait(false);
        var decoder = await BitmapDecoder.CreateAsync(thumb).AsTask(ct).ConfigureAwait(false);
        var pixels = await decoder.GetSoftwareBitmapAsync().AsTask(ct).ConfigureAwait(false);
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, outStream).AsTask(ct).ConfigureAwait(false);
        encoder.SetSoftwareBitmap(pixels);
        await encoder.FlushAsync().AsTask(ct).ConfigureAwait(false);
    }

    public async Task<double> GetDurationSecondsAsync(string inputPath, CancellationToken ct = default)
    {
        var input = await StorageFile.GetFileFromPathAsync(inputPath).AsTask(ct).ConfigureAwait(false);
        var props = await input.Properties.GetVideoPropertiesAsync().AsTask(ct).ConfigureAwait(false);
        return props.Duration.TotalSeconds;
    }

    private static uint Even(uint v) => v % 2 == 0 ? v : v - 1;
}
