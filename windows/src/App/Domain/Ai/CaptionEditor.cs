namespace DemoTape.Domain.Ai;

/// <summary>
/// Pure (no-I/O) cue reconciliation: maps an edited text back onto timed cues.
/// Extracted from the UI layer so it is testable without WinUI.
/// </summary>
public static class CaptionEditor
{
    /// <summary>
    /// Maps edited text lines back onto the original cues' timings by index.
    /// <list type="bullet">
    ///   <item>
    ///     When the edited line count matches the original count: update each cue's
    ///     <c>Text</c> from the edited line while keeping its <c>Start</c>/<c>End</c>
    ///     (the "stale words" fix — timings already cover every token).
    ///   </item>
    ///   <item>
    ///     When the edit shortens the list: excess original cues are dropped.
    ///   </item>
    ///   <item>
    ///     When the edit adds lines beyond the original count: new cues receive zero timing
    ///     (0, 0) and are appended at the end.
    ///   </item>
    /// </list>
    /// Blank lines in <paramref name="edited"/> are ignored.
    /// </summary>
    public static List<CaptionCue> ApplyEdits(IReadOnlyList<CaptionCue> original, string edited)
    {
        var lines = edited
            .Replace("\r\n", "\n")
            .Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToList();

        var result = new List<CaptionCue>(lines.Count);
        for (int i = 0; i < lines.Count; i++)
        {
            // Timings cover this index → keep timing, update text (fix for stale words).
            // Beyond original count → new timeless cue.
            result.Add(i < original.Count
                ? original[i] with { Text = lines[i] }
                : new CaptionCue(0, 0, lines[i]));
        }
        // Any original cues beyond lines.Count are intentionally dropped (edit shortened the list).
        return result;
    }
}
