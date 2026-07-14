using System.Globalization;
using System.Text;
using System.Text.Json;

namespace DemoTape.Domain.Ai;

/// <summary>A single subtitle cue (seconds). Ported from the macOS <c>CaptionCue</c>.</summary>
public readonly record struct CaptionCue(double Start, double End, string Text);

/// <summary>
/// Pure caption formatting/parsing — SRT/VTT writers, an SRT reader (for reusing sidecars), and a
/// parser for OpenAI-compatible <c>verbose_json</c> transcription responses. No I/O, fully testable.
/// </summary>
public static class CaptionFormats
{
    public static string ToSrt(IReadOnlyList<CaptionCue> cues)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < cues.Count; i++)
        {
            sb.Append(i + 1).Append('\n');
            sb.Append(SrtTime(cues[i].Start)).Append(" --> ").Append(SrtTime(cues[i].End)).Append('\n');
            sb.Append(cues[i].Text).Append("\n\n");
        }
        return sb.ToString();
    }

    public static string ToVtt(IReadOnlyList<CaptionCue> cues)
    {
        var sb = new StringBuilder("WEBVTT\n\n");
        foreach (var c in cues)
        {
            sb.Append(VttTime(c.Start)).Append(" --> ").Append(VttTime(c.End)).Append('\n');
            sb.Append(c.Text).Append("\n\n");
        }
        return sb.ToString();
    }

    /// <summary>Parses an OpenAI-compatible verbose_json transcription into cues.</summary>
    public static IReadOnlyList<CaptionCue> ParseVerboseJson(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var cues = new List<CaptionCue>();
        if (root.TryGetProperty("segments", out var segs) && segs.ValueKind == JsonValueKind.Array && segs.GetArrayLength() > 0)
        {
            foreach (var s in segs.EnumerateArray())
            {
                double start = s.TryGetProperty("start", out var st) ? st.GetDouble() : 0;
                double end = s.TryGetProperty("end", out var en) ? en.GetDouble() : 0;
                string text = (s.TryGetProperty("text", out var tx) ? tx.GetString() : "")?.Trim() ?? "";
                if (text.Length > 0) cues.Add(new CaptionCue(start, end, text));
            }
            if (cues.Count > 0) return cues;
        }
        var whole = (root.TryGetProperty("text", out var wt) ? wt.GetString() : "")?.Trim() ?? "";
        return whole.Length == 0 ? Array.Empty<CaptionCue>() : new[] { new CaptionCue(0, 0, whole) };
    }

    /// <summary>Parses SRT text into cues (for reusing sidecars that predate the JSON cache).</summary>
    public static IReadOnlyList<CaptionCue> ParseSrt(string text)
    {
        var cues = new List<CaptionCue>();
        var blocks = text.Replace("\r\n", "\n").Split("\n\n", StringSplitOptions.RemoveEmptyEntries);
        foreach (var block in blocks)
        {
            var lines = block.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            int idx = Array.FindIndex(lines, l => l.Contains("-->"));
            if (idx < 0) continue;
            var parts = lines[idx].Split("-->");
            if (parts.Length != 2 || SrtSeconds(parts[0]) is not double start || SrtSeconds(parts[1]) is not double end) continue;
            var body = string.Join(' ', lines[(idx + 1)..]).Trim();
            if (body.Length > 0) cues.Add(new CaptionCue(start, end, body));
        }
        return cues;
    }

    private static double? SrtSeconds(string s)
    {
        var t = s.Trim().Replace(',', '.');
        var hms = t.Split(':');
        if (hms.Length != 3) return null;
        if (double.TryParse(hms[0], NumberStyles.Any, CultureInfo.InvariantCulture, out var h) &&
            double.TryParse(hms[1], NumberStyles.Any, CultureInfo.InvariantCulture, out var m) &&
            double.TryParse(hms[2], NumberStyles.Any, CultureInfo.InvariantCulture, out var sec))
            return h * 3600 + m * 60 + sec;
        return null;
    }

    private static (int h, int m, int s, int ms) Hms(double t)
    {
        int total = (int)Math.Round(Math.Max(0, t) * 1000);
        return (total / 3_600_000, total % 3_600_000 / 60_000, total % 60_000 / 1000, total % 1000);
    }

    private static string SrtTime(double t) { var (h, m, s, ms) = Hms(t); return $"{h:00}:{m:00}:{s:00},{ms:000}"; }
    private static string VttTime(double t) { var (h, m, s, ms) = Hms(t); return $"{h:00}:{m:00}:{s:00}.{ms:000}"; }
}
