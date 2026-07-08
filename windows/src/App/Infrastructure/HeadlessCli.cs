using DemoTape.Services;
using Microsoft.Extensions.Logging.Abstractions;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Headless command-line hooks for testing the encode pipeline without a GUI — the Windows
/// equivalent of the macOS <c>--render</c>/<c>--transcode</c> hooks.
///
///   DemoTape --transcode &lt;input.mp4&gt; &lt;height&gt; &lt;output.mp4&gt;
///   DemoTape --publish   &lt;styled.mp4&gt; &lt;360,540,720&gt;
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
            var svc = new WebPublishService(transcoder);
            var result = await svc.PublishAsync(source, tiers);
            Console.WriteLine($"published: {result.OutputFolder}");
            return true;
        }

        return false;
    }
}
