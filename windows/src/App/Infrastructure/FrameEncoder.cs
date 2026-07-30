using System.Runtime.Versioning;
using System.Text.Json;
using System.Text.Json.Serialization;
using Windows.Graphics.Imaging;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.Streams;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Encodes a captured sequence of still frames (JPEGs + a <c>manifest.json</c>) into a raw MP4 that
/// <c>--render</c> then styles — the Windows port of the macOS <c>--encode-frames</c> / <c>FrameEncoder</c>.
///
/// <para>Why it exists: an agent driving a browser can capture the page over the DevTools protocol
/// (<c>Page.startScreencast</c>) with <b>no screen-capture permission</b> and write the <c>events.json</c>
/// sidecar itself (it caused every click/keystroke). Turning those frames into a video here means the
/// whole agentic path — capture → style → verify — works headless, and <c>--render</c> can't tell the
/// difference from a real screen recording.</para>
///
/// <para>Each captured frame becomes an image clip held until the next frame's timestamp; the final
/// image is held out to the manifest's <c>duration</c> (which is longer than the last frame whenever the
/// page stopped repainting on a still result), so the closing beat — and any narration over it — isn't
/// cut off. The renderer samples the composition at a constant rate, so the held frames read smoothly.</para>
/// </summary>
[SupportedOSPlatform("windows10.0.17763.0")]
public sealed class FrameEncoder
{
    private sealed record Manifest(
        [property: JsonPropertyName("width")] double? Width,
        [property: JsonPropertyName("height")] double? Height,
        [property: JsonPropertyName("fps")] double? Fps,
        [property: JsonPropertyName("duration")] double? Duration,
        [property: JsonPropertyName("frames")] List<Frame>? Frames);

    private sealed record Frame(
        [property: JsonPropertyName("path")] string Path,
        [property: JsonPropertyName("t")] double? T);

    /// <summary>Encodes <paramref name="manifestPath"/> into <paramref name="outPath"/>. Returns the output path.</summary>
    public async Task<string> EncodeAsync(string manifestPath, string outPath, Action<double>? progress = null)
    {
        var dir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(manifestPath))!;
        var manifest = JsonSerializer.Deserialize<Manifest>(await File.ReadAllTextAsync(manifestPath))
                       ?? throw new InvalidOperationException("Unreadable frame manifest.");
        if (manifest.Frames is null || manifest.Frames.Count == 0)
            throw new InvalidOperationException("The frame manifest lists no frames.");

        double fps = (manifest.Fps ?? 30) > 0 ? manifest.Fps!.Value : 30;

        // Resolve to absolute paths + a strictly-increasing timeline. A screencast delivers frames as
        // they're produced, so duplicate/out-of-order timestamps are normal; nudge non-advancing ones
        // just past their predecessor rather than dropping any captured frame.
        var resolved = new List<(string Path, double T)>();
        for (int i = 0; i < manifest.Frames.Count; i++)
        {
            var f = manifest.Frames[i];
            if (string.IsNullOrEmpty(f.Path)) continue;
            var p = System.IO.Path.IsPathRooted(f.Path)
                ? f.Path
                : System.IO.Path.Combine(dir, f.Path.Replace('/', System.IO.Path.DirectorySeparatorChar));
            double t = f.T ?? (i / fps);
            if (double.IsNaN(t) || double.IsInfinity(t) || t < 0) continue;
            if (resolved.Count > 0 && t <= resolved[^1].T) t = resolved[^1].T + 1 / (fps * 4);
            resolved.Add((p, t));
        }
        if (resolved.Count == 0) throw new InvalidOperationException("No usable frames in the manifest.");

        double totalDuration = Math.Max(manifest.Duration ?? resolved[^1].T, resolved[^1].T);
        if (totalDuration <= 0) totalDuration = resolved.Count / fps;

        // Decode each captured frame once to a tightly-packed BGRA8 buffer. All frames share the
        // viewport size, so the first frame fixes the output dimensions. (MediaComposition image
        // clips fail to render headless with MF_E_UNSUPPORTED_FORMAT, so we feed a MediaStreamSource
        // of uncompressed frames to a MediaTranscoder instead — the canonical images→video path.)
        int outW = 0, outH = 0;
        var buffers = new List<IBuffer>(resolved.Count);
        for (int i = 0; i < resolved.Count; i++)
        {
            var (buf, w, h) = await DecodeBgra8Async(resolved[i].Path);
            if (outW == 0) { outW = Even(w); outH = Even(h); }
            buffers.Add(buf);
            progress?.Invoke((double)i / resolved.Count * 0.4);
        }
        if (outW < 2 || outH < 2) throw new InvalidOperationException("Frame dimensions are invalid.");

        // Build a constant-rate (30 fps) uncompressed source, holding each captured image until the
        // next one's timestamp and out to the full duration — so a static closing beat isn't cut off.
        const double outFps = 30.0;
        int totalFrames = Math.Max(1, (int)Math.Round(totalDuration * outFps));
        var frameDuration = TimeSpan.FromSeconds(1.0 / outFps);

        var videoProps = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)outW, (uint)outH);
        var descriptor = new VideoStreamDescriptor(videoProps);
        var mss = new MediaStreamSource(descriptor)
        {
            BufferTime = TimeSpan.Zero,
            Duration = TimeSpan.FromSeconds(totalDuration),
        };
        mss.Starting += (_, e) => e.Request.SetActualStartPosition(TimeSpan.Zero);

        int emitted = 0, captureIndex = 0;
        mss.SampleRequested += (_, e) =>
        {
            if (emitted >= totalFrames) { e.Request.Sample = null; return; } // end of stream
            double t = emitted / outFps;
            while (captureIndex + 1 < resolved.Count && resolved[captureIndex + 1].T <= t + 1e-6) captureIndex++;
            var sample = MediaStreamSample.CreateFromBuffer(buffers[captureIndex], TimeSpan.FromSeconds(t));
            sample.Duration = frameDuration;
            e.Request.Sample = sample;
            emitted++;
        };

        var h264 = VideoEncodingProperties.CreateH264();
        h264.Width = (uint)outW; h264.Height = (uint)outH;
        h264.Bitrate = (uint)(outW * outH * 8);
        h264.FrameRate.Numerator = 30; h264.FrameRate.Denominator = 1;
        h264.PixelAspectRatio.Numerator = 1; h264.PixelAspectRatio.Denominator = 1;
        var profile = new MediaEncodingProfile
        {
            Container = new ContainerEncodingProperties { Subtype = MediaEncodingSubtypes.Mpeg4 },
            Video = h264,
        };

        var outDir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(outPath))!;
        var folder = await StorageFolder.GetFolderFromPathAsync(outDir);
        var outFile = await folder.CreateFileAsync(System.IO.Path.GetFileName(outPath), CreationCollisionOption.ReplaceExisting);
        using (var outStream = await outFile.OpenAsync(FileAccessMode.ReadWrite))
        {
            var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
            var prep = await transcoder.PrepareMediaStreamSourceTranscodeAsync(mss, outStream, profile);
            if (!prep.CanTranscode)
                throw new InvalidOperationException($"Frame encode can't transcode ({prep.FailureReason}).");
            await prep.TranscodeAsync();
        }
        progress?.Invoke(1.0);
        return outPath;
    }

    private static int Even(int v) => v % 2 == 0 ? v : v + 1;

    /// <summary>Decodes an image file to a tightly-packed BGRA8 buffer + its pixel dimensions.</summary>
    private static async Task<(IBuffer Buffer, int Width, int Height)> DecodeBgra8Async(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        using var stream = await file.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var bmp = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        int w = bmp.PixelWidth, h = bmp.PixelHeight;
        var buffer = new Windows.Storage.Streams.Buffer((uint)(w * h * 4));
        bmp.CopyToBuffer(buffer);
        return (buffer, w, h);
    }
}
