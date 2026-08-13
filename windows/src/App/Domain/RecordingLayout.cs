namespace DemoTape.Domain;

/// <summary>
/// Determines the "best" derivative of a recording to open for post-processing or publishing.
/// Priority order (highest to lowest): captioned > tight > voiceover > avatar > styled > raw.
/// Mirrors the macOS <c>RecordingLayout.latestSource()</c>.
/// </summary>
public static class RecordingLayout
{
    // Ordered suffixes from most-processed to least-processed. The "raw" entry uses a sentinel
    // value because it is the catch-all for any *.mp4 that does not match a derivative suffix.
    private static readonly string[] DerivativeSuffixes =
    {
        ".captioned.mp4",
        ".tight.mp4",
        ".voiceover.mp4",
        ".avatar.mp4",
        ".styled.mp4",
    };

    // Suffixes that identify camera/sidecar files — excluded from the raw fallback.
    private static readonly string[] SidecarSuffixes =
    {
        ".cam.mp4",
    };

    /// <summary>
    /// Returns the path of the highest-priority derivative found in
    /// <paramref name="recordingFolder"/>, or <c>null</c> if the folder is empty or missing.
    /// Ties at the same priority level are broken by file modification time (newest wins).
    /// </summary>
    public static string? LatestSource(string? recordingFolder)
    {
        if (string.IsNullOrEmpty(recordingFolder) || !Directory.Exists(recordingFolder))
            return null;

        var allMp4 = Directory.EnumerateFiles(recordingFolder, "*.mp4")
            .Select(p => new FileInfo(p))
            .Where(f => f.Exists)
            .ToList();

        if (allMp4.Count == 0) return null;

        // Check known derivative suffixes in priority order.
        foreach (var suffix in DerivativeSuffixes)
        {
            var best = allMp4
                .Where(f => f.Name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(f => f.LastWriteTimeUtc)
                .FirstOrDefault();
            if (best is not null) return best.FullName;
        }

        // Fallback: raw .mp4 — exclude all known derivatives and sidecars.
        var allKnownSuffixes = DerivativeSuffixes.Concat(SidecarSuffixes).ToArray();
        var rawBest = allMp4
            .Where(f => !allKnownSuffixes.Any(s => f.Name.EndsWith(s, StringComparison.OrdinalIgnoreCase)))
            .OrderByDescending(f => f.LastWriteTimeUtc)
            .FirstOrDefault();
        return rawBest?.FullName;
    }
}
