namespace DemoTape.Domain.Audio;

/// <summary>
/// Loudness-normalization math ported from the macOS renderer's <c>normalizedGain</c>.
/// Built-in mics record quietly, so we raise the track toward a broadcast-like RMS without
/// letting peaks clip, adapting per-recording instead of using a fixed multiplier.
///
/// The PCM scanning that produces <c>peak</c>/<c>rms</c> is a platform concern; this pure
/// function is the testable decision logic.
/// </summary>
public static class AudioNormalizer
{
    /// <summary>Target RMS (~-16 dBFS), matching the macOS implementation.</summary>
    public const double TargetRms = 0.16;

    /// <summary>Default gain when the track can't be analyzed (parity with macOS fallback).</summary>
    public const double DefaultGain = 4.0;

    /// <summary>Below this peak the track is treated as silence and left untouched.</summary>
    public const double SilenceThreshold = 0.0005;

    public const double MaxGain = 30.0;

    /// <summary>
    /// Computes a linear gain factor for a normalized (0..1) <paramref name="peak"/> and
    /// <paramref name="rms"/>. Returns 1.0 for silence; otherwise raises RMS toward the
    /// target while guarding peaks at 0.97, clamped to [1, 30].
    /// </summary>
    public static double ComputeGain(double peak, double rms)
    {
        if (peak <= SilenceThreshold) return 1.0; // silence

        double rmsGain = rms > 0 ? TargetRms / rms : MaxGain;
        double peakGuard = 0.97 / peak;
        return Math.Clamp(Math.Max(Math.Min(rmsGain, peakGuard), 1.0), 1.0, MaxGain);
    }
}
