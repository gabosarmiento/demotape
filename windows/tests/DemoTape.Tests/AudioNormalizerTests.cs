using DemoTape.Domain.Audio;
using Xunit;

namespace DemoTape.Tests;

public class AudioNormalizerTests
{
    [Fact]
    public void Silence_LeavesGainAtUnity()
    {
        Assert.Equal(1.0, AudioNormalizer.ComputeGain(peak: 0.0001, rms: 0.00005));
    }

    [Fact]
    public void QuietMic_IsBoostedTowardTarget_WithoutClipping()
    {
        // Quiet recording: low RMS, low peak. Gain raises RMS toward 0.16 but respects peak guard.
        double gain = AudioNormalizer.ComputeGain(peak: 0.05, rms: 0.02);
        double expectedRmsGain = AudioNormalizer.TargetRms / 0.02; // 8.0
        double peakGuard = 0.97 / 0.05;                             // 19.4
        Assert.Equal(Math.Min(expectedRmsGain, peakGuard), gain, 6);
        // Applying the gain keeps the peak under 1.0 (no clipping).
        Assert.True(0.05 * gain <= 0.97 + 1e-9);
    }

    [Fact]
    public void LoudRecording_IsNotAmplifiedBelowUnity()
    {
        // Already loud: RMS above target would compute gain < 1; clamped to 1.
        double gain = AudioNormalizer.ComputeGain(peak: 0.9, rms: 0.3);
        Assert.Equal(1.0, gain, 6);
    }

    [Fact]
    public void PeakGuard_CapsGain_ToPreventClipping()
    {
        // Very quiet RMS wants a huge gain, but a moderate peak limits it.
        double gain = AudioNormalizer.ComputeGain(peak: 0.5, rms: 0.001);
        Assert.Equal(0.97 / 0.5, gain, 6);
    }

    [Fact]
    public void Gain_IsClampedToMax()
    {
        double gain = AudioNormalizer.ComputeGain(peak: 0.001, rms: 0.0001);
        Assert.True(gain <= AudioNormalizer.MaxGain);
    }
}
