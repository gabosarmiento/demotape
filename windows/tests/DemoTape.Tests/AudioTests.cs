using DemoTape.Domain.Audio;
using Xunit;

namespace DemoTape.Tests;

public class AudioTests
{
    [Fact]
    public void KeepRanges_TrimsLongMiddleSilence()
    {
        // 10 windows of 1s each; loud 0-2, silent 2-8 (6s), loud 8-10.
        var flags = new[] { true, true, false, false, false, false, false, false, true, true };
        var keep = SilencePlanner.KeepRanges(flags, 1.0, 10.0, minSilence: 0.6, padding: 0.1);
        Assert.Equal(2, keep.Count);
        Assert.Equal(0, keep[0].Start, 3);
        Assert.True(keep[0].End <= 2.2 && keep[0].End >= 2.0); // padded end near content
        Assert.True(keep[1].Start >= 7.8 && keep[1].Start <= 8.0);
    }

    [Fact]
    public void KeepRanges_KeepsAllWhenNoLongSilence()
    {
        var flags = new[] { true, true, true, true };
        var keep = SilencePlanner.KeepRanges(flags, 1.0, 4.0, 0.6, 0.1);
        Assert.Single(keep);
        Assert.Equal(0, keep[0].Start, 3);
        Assert.Equal(4.0, keep[0].End, 3);
    }

    [Fact]
    public void Loudness_FlagsQuietWindowsAsSilent()
    {
        int rate = 16000;
        var mono = new float[rate * 2]; // 2s
        // First second loud (0.5 amplitude), second second silent.
        for (int i = 0; i < rate; i++) mono[i] = (i % 2 == 0) ? 0.5f : -0.5f;
        var (flags, win) = SilencePlanner.Loudness(mono, rate, thresholdDb: -40);
        Assert.Equal(0.03, win, 3);
        Assert.True(flags[0]);            // loud
        Assert.False(flags[^1]);          // silent tail
    }

    [Fact]
    public void NoiseGate_AttenuatesQuietTail()
    {
        int rate = 16000;
        var x = new float[rate];          // 1s
        for (int i = 0; i < rate / 2; i++) x[i] = (i % 2 == 0) ? 0.4f : -0.4f;   // loud first half
        for (int i = rate / 2; i < rate; i++) x[i] = (i % 2 == 0) ? 0.002f : -0.002f; // faint noise tail
        var outp = AudioDsp.NoiseGate(x, rate, strength: 1.0);
        float tail = 0; for (int i = rate - 100; i < rate; i++) tail += MathF.Abs(outp[i]);
        Assert.True(tail < 0.05f); // quiet tail suppressed
    }

    [Fact]
    public void Enhance_DoesNotClipAndKeepsLength()
    {
        int rate = 48000;
        var x = new float[rate];
        for (int i = 0; i < rate; i++) x[i] = 0.8f * MathF.Sin(2 * MathF.PI * 220 * i / rate);
        var outp = AudioDsp.Enhance(new[] { x }, rate)[0];
        Assert.Equal(x.Length, outp.Length);
        foreach (var v in outp) Assert.True(MathF.Abs(v) <= 1.0f);
    }
}
