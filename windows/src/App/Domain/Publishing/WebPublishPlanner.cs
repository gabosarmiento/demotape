using System.Text;

namespace DemoTape.Domain.Publishing;

/// <summary>
/// Pure planning/estimation logic for Web Publish, ported from the macOS
/// <c>Transcoder</c> bitrate tables and <c>WebPublishController.publish</c> file generation.
/// Contains no I/O and no platform APIs, so it is fully unit-testable. The actual transcoding
/// is delegated to a platform <c>IVideoTranscoder</c> (Media Foundation on Windows).
/// </summary>
public static class WebPublishPlanner
{
    /// <summary>Height tiers offered in the UI.</summary>
    public static readonly IReadOnlyList<int> Tiers = new[] { 360, 480, 540, 720 };

    /// <summary>Video bitrate (kbps) per height tier. Tuned for small, fast-loading demo clips.</summary>
    public static readonly IReadOnlyDictionary<int, int> BitrateKbps = new Dictionary<int, int>
    {
        [360] = 910,
        [480] = 1430,
        [540] = 1820,
        [720] = 2860,
    };

    /// <summary>Responsive-embed media-query breakpoints (min-width px) per tier.</summary>
    private static readonly IReadOnlyDictionary<int, int> Breakpoints = new Dictionary<int, int>
    {
        [720] = 1000,
        [540] = 760,
        [480] = 560,
        [360] = 400,
    };

    /// <summary>Estimated output size in bytes for a duration (s) and tier (px height).</summary>
    public static long EstimatedBytes(double durationSeconds, int height, int audioKbps = 96)
    {
        int v = BitrateKbps.TryGetValue(height, out var kbps) ? kbps : 1400;
        return (long)(durationSeconds * (v + audioKbps) * 1000 / 8);
    }

    /// <summary>Total estimated bytes across a set of selected tiers.</summary>
    public static long EstimatedBytes(double durationSeconds, IEnumerable<int> heights, int audioKbps = 96)
        => heights.Sum(h => EstimatedBytes(durationSeconds, h, audioKbps));

    /// <summary>Human-readable estimate line, e.g. "≈ 4.2 MB total · 540p, 720p · 30s".</summary>
    public static string EstimateSummary(double durationSeconds, IReadOnlyCollection<int> heights)
    {
        if (heights.Count == 0) return "Select at least one quality.";
        double mb = EstimatedBytes(durationSeconds, heights) / 1_000_000.0;
        string tiers = string.Join(", ", heights.OrderBy(h => h).Select(h => $"{h}p"));
        return $"≈ {mb:0.0} MB total  ·  {tiers}  ·  {durationSeconds:0}s";
    }

    /// <summary>The output file name for a tier, e.g. "demo-540p.mp4".</summary>
    public static string TierFileName(int height) => $"demo-{height}p.mp4";

    /// <summary>Derives the "<name>-web" output folder name from a styled source file name.</summary>
    public static string WebFolderName(string styledFileNameWithoutExtension)
        => $"{styledFileNameWithoutExtension.Replace(".styled", string.Empty)}-web";

    /// <summary>
    /// Builds a responsive <c>&lt;video&gt;</c> snippet: largest source first with media queries,
    /// smallest as the fallback. Mirrors the macOS embed generation.
    /// </summary>
    public static string BuildEmbedHtml(IEnumerable<int> heights)
    {
        var desc = heights.Distinct().OrderByDescending(h => h).ToList();
        var sources = new StringBuilder();
        for (int i = 0; i < desc.Count; i++)
        {
            int h = desc[i];
            string name = TierFileName(h);
            if (i < desc.Count - 1 && Breakpoints.TryGetValue(h, out int bp))
                sources.Append($"  <source src=\"{name}\" type=\"video/mp4\" media=\"(min-width: {bp}px)\">\n");
            else
                sources.Append($"  <source src=\"{name}\" type=\"video/mp4\">\n");
        }
        return "<video controls muted loop playsinline preload=\"metadata\" poster=\"poster.jpg\" width=\"100%\">\n"
             + sources
             + "</video>";
    }

    /// <summary>Builds the README.txt shipped in the web folder.</summary>
    public static string BuildReadme(IEnumerable<int> heights)
    {
        var desc = heights.Distinct().OrderByDescending(h => h).ToList();
        string fileList = string.Join(", ", desc.Select(TierFileName));
        return $"""
        DemoTape — Web Publish
        =======================
        Files: {fileList}   H.264 High + AAC, MP4 faststart. Lightweight, fast-loading.
        poster.jpg   First-frame thumbnail for <video poster="…">.
        embed.html   Responsive <video> snippet for your page. Muted + loop = autoplay-friendly.

        Uploading to X / LinkedIn: upload the largest mp4 directly — they re-encode it.
        Hosting on your site: upload all files and use embed.html (serves the right size per screen).
        """;
    }
}
