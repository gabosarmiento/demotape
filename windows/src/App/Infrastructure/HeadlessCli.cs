using DemoTape.Services;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Headless command-line hooks for testing the pipeline without the GUI — the Windows
/// equivalent of the macOS <c>--render</c>/<c>--transcode</c> hooks.
///
///   DemoTape --transcode &lt;input.mp4&gt; &lt;height&gt; &lt;output.mp4&gt;
///   DemoTape --publish   &lt;styled.mp4&gt; &lt;360,540,720&gt;
///   DemoTape --capture-test &lt;seconds&gt; &lt;output.mp4&gt;   (records the primary display)
/// </summary>
public static class HeadlessCli
{
    /// <summary>Returns true if a headless command was recognized and executed (caller should exit).</summary>
    public static async Task<bool> TryRunAsync(string[] args)
    {
        var transcoder = new MediaFoundationTranscoder(NullLogger<MediaFoundationTranscoder>.Instance);

        int t = Array.IndexOf(args, "--transcode");
        if (t >= 0 && args.Length > t + 3)
        {
            var input = args[t + 1];
            var height = int.TryParse(args[t + 2], out var h) ? h : 540;
            var output = args[t + 3];
            await transcoder.TranscodeAsync(input, output, height);
            Console.WriteLine($"transcoded: {output}");
            return true;
        }

        int p = Array.IndexOf(args, "--publish");
        if (p >= 0 && args.Length > p + 2)
        {
            var source = args[p + 1];
            var tiers = args[p + 2].Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(s => int.TryParse(s, out var v) ? v : 0)
                .Where(v => v > 0)
                .ToArray();
            var svc = new WebPublishService(transcoder, new GifEncoder());
            var result = await svc.PublishAsync(source, tiers);
            Console.WriteLine($"published: {result.OutputFolder}");
            return true;
        }

        int z = Array.IndexOf(args, "--zoom-check");
        if (z >= 0 && args.Length > z + 1)
        {
            var sidecar = args[z + 1];
            var meta = System.Text.Json.JsonSerializer.Deserialize<DemoTape.Domain.Models.RecordingMetadata>(
                File.ReadAllText(sidecar),
                new System.Text.Json.JsonSerializerOptions { PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase })!;
            var focus = new DemoTape.Domain.Rendering.FocusTimeline(meta, 2.0);
            var cam = new DemoTape.Domain.Rendering.SpringCamera();
            double fps = 30, maxScale = 0, minScale = 99;
            int frames = (int)(meta.Duration * fps);
            for (int i = 0; i < frames; i++)
            {
                double ft = i / fps;
                var tgt = focus.Target(ft + (meta.EventTimeOffset ?? 0));
                cam.Step(tgt, 1.0 / fps);
                maxScale = Math.Max(maxScale, cam.Scale);
                minScale = Math.Min(minScale, cam.Scale);
                if (i % 30 == 0) Console.WriteLine($"t={ft:0.0}s targetScale={tgt.Scale:0.00} camScale={cam.Scale:0.00} center=({cam.CenterX:0.00},{cam.CenterY:0.00})");
            }
            Console.WriteLine($"zoom-check: minScale={minScale:0.00} maxScale={maxScale:0.00} frames={frames}");
            return true;
        }

        int fr = Array.IndexOf(args, "--frame");
        if (fr >= 0 && args.Length > fr + 3)
        {
            var video = args[fr + 1];
            var seconds = double.Parse(args[fr + 2], System.Globalization.CultureInfo.InvariantCulture);
            var outPng = args[fr + 3];
            var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(video);
            var clip = await Windows.Media.Editing.MediaClip.CreateFromFileAsync(file);
            var comp = new Windows.Media.Editing.MediaComposition();
            comp.Clips.Add(clip);
            using var stream = await comp.GetThumbnailAsync(TimeSpan.FromSeconds(seconds), 0, 0,
                Windows.Media.Editing.VideoFramePrecision.NearestFrame);
            var outFolder = await Windows.Storage.StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(outPng)!);
            var outFile = await outFolder.CreateFileAsync(Path.GetFileName(outPng), Windows.Storage.CreationCollisionOption.ReplaceExisting);
            var dec = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
            using var sbmp = await dec.GetSoftwareBitmapAsync();
            using var outStream = await outFile.OpenAsync(Windows.Storage.FileAccessMode.ReadWrite);
            var enc = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, outStream);
            enc.SetSoftwareBitmap(sbmp);
            await enc.FlushAsync();
            Console.WriteLine($"frame: {outPng} ({dec.PixelWidth}x{dec.PixelHeight})");
            return true;
        }

        int r = Array.IndexOf(args, "--render");
        if (r >= 0 && args.Length > r + 2)
        {
            var raw = args[r + 1];
            var output = args[r + 2];
            var sidecar = raw.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase)
                ? raw[..^4] + ".events.json"
                : raw + ".events.json";
            var renderer = new StyledVideoRenderer(new ConsoleLogger<StyledVideoRenderer>());
            var settingsStore = new JsonSettingsStore(new PathService(), NullLogger<JsonSettingsStore>.Instance);
            var settings = settingsStore.Load();
            var cam = raw.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase) ? raw[..^4] + ".cam.mp4" : null;
            var camPath = cam is not null && File.Exists(cam) ? cam : null;
            Console.WriteLine($"render: {raw} (+ {Path.GetFileName(sidecar)}) region={settings.UseRegion} cam={camPath is not null} -> {output}");
            var result = await renderer.RenderAsync(raw, sidecar, output, settings, cameraPath: camPath);
            Console.WriteLine(result is null ? "render: FAILED" : $"render: OK -> {output} ({new FileInfo(output).Length / 1024} KB)");
            return true;
        }

        int au = Array.IndexOf(args, "--audio-test");
        if (au >= 0 && args.Length > au + 2)
        {
            var inFile = args[au + 1];
            var outFile = args[au + 2];
            var (samples, rate) = await WavAudioIo.ExtractMonoAsync(inFile, 48000);
            Console.WriteLine($"audio-test: extracted {samples.Length} samples @ {rate}Hz ({samples.Length / (double)rate:0.0}s)");
            samples = DemoTape.Domain.Audio.AudioDsp.NoiseGate(samples, rate, 0.7);
            samples = DemoTape.Domain.Audio.AudioDsp.Enhance(new[] { samples }, rate)[0];
            await WavAudioIo.EncodeMonoToM4aAsync(samples, rate, outFile);
            Console.WriteLine($"audio-test: wrote {outFile} ({new FileInfo(outFile).Length / 1024} KB)");
            return true;
        }

        int st = Array.IndexOf(args, "--selector-test");
        if (st >= 0)
        {
            int secs = args.Length > st + 1 && int.TryParse(args[st + 1], out var ss) ? ss : 5;
            Console.WriteLine($"selector-test: showing region selector for {secs}s (check overlay.log)");
            var done = new TaskCompletionSource();
            var overlay = new RegionSelectorOverlay(_ => { }, () => done.TrySetResult());
            await Task.WhenAny(done.Task, Task.Delay(secs * 1000));
            overlay.Dispose();
            Console.WriteLine("selector-test: done");
            return true;
        }

        int c = Array.IndexOf(args, "--capture-test");
        if (c >= 0 && args.Length > c + 2)
        {
            int seconds = int.TryParse(args[c + 1], out var s) ? s : 5;
            var output = args[c + 2];
            var recorder = new ScreenCaptureRecorder(new ConsoleLogger<ScreenCaptureRecorder>());
            Console.WriteLine($"capture-test: recording {seconds}s -> {output}");
            recorder.Start(output);
            await Task.Delay(seconds * 1000);
            var result = await recorder.StopAsync();
            if (result is null || !File.Exists(output))
                Console.WriteLine("capture-test: FAILED (no file produced)");
            else
                Console.WriteLine($"capture-test: OK -> {output} ({new FileInfo(output).Length / 1024} KB)");
            return true;
        }

        return false;
    }
}

/// <summary>Minimal console logger for the headless self-test hooks.</summary>
internal sealed class ConsoleLogger<T> : ILogger<T>
{
    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
    public bool IsEnabled(LogLevel logLevel) => true;
    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
        Func<TState, Exception?, string> formatter)
    {
        Console.WriteLine($"[{logLevel}] {formatter(state, exception)}");
        if (exception is not null) Console.WriteLine(exception);
    }
}
