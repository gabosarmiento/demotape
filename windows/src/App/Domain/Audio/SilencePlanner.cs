namespace DemoTape.Domain.Audio;

/// <summary>A time range in seconds.</summary>
public readonly record struct TimeSpanRange(double Start, double End)
{
    public double Duration => End - Start;
}

/// <summary>
/// Pure silence-analysis for Auto-Cut, ported from the macOS <c>Tightener.keepRanges</c>. Given
/// per-window loudness flags, returns the time ranges to KEEP (silent gaps longer than
/// <paramref name="minSilence"/> are trimmed, leaving <paramref name="padding"/> next to content).
/// </summary>
public static class SilencePlanner
{
    public static IReadOnlyList<TimeSpanRange> KeepRanges(
        IReadOnlyList<bool> isLoud, double windowDuration, double duration, double minSilence, double padding)
    {
        if (isLoud.Count == 0) return new[] { new TimeSpanRange(0, duration) };

        var cuts = new List<TimeSpanRange>();
        int i = 0;
        while (i < isLoud.Count)
        {
            if (isLoud[i]) { i++; continue; }
            int j = i;
            while (j < isLoud.Count && !isLoud[j]) j++;
            double silStart = i * windowDuration;
            double silEnd = Math.Min(j * windowDuration, duration);
            if (silEnd - silStart >= minSilence)
            {
                bool atStart = i == 0, atEnd = j >= isLoud.Count;
                double cutStart = atStart ? silStart : silStart + padding;
                double cutEnd = atEnd ? silEnd : silEnd - padding;
                if (cutEnd > cutStart) cuts.Add(new TimeSpanRange(cutStart, cutEnd));
            }
            i = j;
        }
        if (cuts.Count == 0) return new[] { new TimeSpanRange(0, duration) };

        var keep = new List<TimeSpanRange>();
        double cursor = 0;
        foreach (var cut in cuts)
        {
            if (cut.Start > cursor) keep.Add(new TimeSpanRange(cursor, cut.Start));
            cursor = cut.End;
        }
        if (cursor < duration) keep.Add(new TimeSpanRange(cursor, duration));
        return keep.Where(r => r.Duration > 0.02).ToList();
    }

    /// <summary>Per-window loudness flags from mono PCM: RMS per window compared to <paramref name="thresholdDb"/> (dBFS).</summary>
    public static (IReadOnlyList<bool> flags, double window) Loudness(float[] mono, double sampleRate, float thresholdDb, double windowSeconds = 0.03)
    {
        int win = Math.Max(1, (int)(sampleRate * windowSeconds));
        int count = (mono.Length + win - 1) / win;
        var flags = new bool[count];
        for (int w = 0; w < count; w++)
        {
            int start = w * win, n = Math.Min(win, mono.Length - start);
            double sum = 0;
            for (int k = 0; k < n; k++) { double v = mono[start + k]; sum += v * v; }
            double rms = Math.Sqrt(sum / Math.Max(1, n));
            double db = rms > 0 ? 20 * Math.Log10(rms) : -120.0; // input already -1..1
            flags[w] = db >= thresholdDb;
        }
        return (flags, windowSeconds);
    }
}
