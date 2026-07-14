using System.Text;
using System.Text.Json;

namespace DemoTape.Domain.Ai;

/// <summary>An ElevenLabs voice. Ported from the macOS <c>Voiceover.Voice</c>.</summary>
public sealed record Voice(string Id, string Name, string Gender, string Accent, string PreviewUrl)
{
    public string Label => string.IsNullOrEmpty(Accent) ? Name : $"{Name} ({Accent})";
}

/// <summary>Pure voiceover helpers: parse the ElevenLabs voice list, build a script from a transcript,
/// and derive output/narration file names. No I/O, fully testable.</summary>
public static class VoiceoverPlanner
{
    public static IReadOnlyList<Voice> ParseVoices(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var list = new List<Voice>();
        if (!doc.RootElement.TryGetProperty("voices", out var voices) || voices.ValueKind != JsonValueKind.Array)
            return list;
        foreach (var v in voices.EnumerateArray())
        {
            string id = v.TryGetProperty("voice_id", out var vid) ? vid.GetString() ?? "" : "";
            string name = v.TryGetProperty("name", out var nm) ? nm.GetString() ?? "" : "";
            string gender = "", accent = "";
            if (v.TryGetProperty("labels", out var labels) && labels.ValueKind == JsonValueKind.Object)
            {
                if (labels.TryGetProperty("gender", out var g)) gender = g.GetString() ?? "";
                if (labels.TryGetProperty("accent", out var a)) accent = a.GetString() ?? "";
            }
            string preview = v.TryGetProperty("preview_url", out var pu) ? pu.GetString() ?? "" : "";
            if (id.Length > 0) list.Add(new Voice(id, name, gender, accent, preview));
        }
        return list;
    }

    /// <summary>Joins transcript cues into a single readable script (what pre-fills the editor).</summary>
    public static string ScriptFromCues(IReadOnlyList<CaptionCue> cues)
    {
        var sb = new StringBuilder();
        foreach (var c in cues)
        {
            var t = c.Text.Trim();
            if (t.Length == 0) continue;
            if (sb.Length > 0) sb.Append(' ');
            sb.Append(t);
        }
        return sb.ToString();
    }

    /// <summary><c>…voiceover.mp4</c> beside the source (strips a <c>.styled</c> marker).</summary>
    public static string OutputPath(string video) => Beside(video, ".voiceover.mp4");

    /// <summary>Durable narration audio (<c>…voiceover.narration.mp3</c>) — kept for avatar reuse.</summary>
    public static string NarrationPath(string video) => Beside(video, ".voiceover.narration.mp3");

    /// <summary><c>…captioned.mp4</c> beside the source.</summary>
    public static string CaptionedPath(string video) => Beside(video, ".captioned.mp4");

    /// <summary><c>…avatar.mp4</c> beside the source.</summary>
    public static string AvatarPath(string video) => Beside(video, ".avatar.mp4");

    /// <summary>Cached transcript path (<c>…transcript.json</c>) beside the source.</summary>
    public static string TranscriptPath(string video)
    {
        var dir = Path.GetDirectoryName(video) ?? "";
        var name = StripStyled(Path.GetFileNameWithoutExtension(video));
        return Path.Combine(dir, name + ".transcript.json");
    }

    private static string Beside(string video, string suffix)
    {
        var dir = Path.GetDirectoryName(video) ?? "";
        var name = StripStyled(Path.GetFileNameWithoutExtension(video));
        return Path.Combine(dir, name + suffix);
    }

    private static string StripStyled(string name)
        => name.EndsWith(".styled", StringComparison.OrdinalIgnoreCase) ? name[..^".styled".Length] : name;
}
