using DemoTape.Domain.Audio;
using Microsoft.Extensions.Logging;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Applies on-device audio cleanup — Smart Noise Suppression (gate) then Enhance Voice (studio EQ +
/// compressor) — to a narration audio file IN PLACE, before it's muxed into the styled video. Mirrors
/// the macOS "denoise, then enhance, in place" step. Best-effort: on any failure the audio is left as-is.
/// </summary>
public sealed class AudioEnhancementService
{
    private readonly ILogger<AudioEnhancementService> _logger;
    public AudioEnhancementService(ILogger<AudioEnhancementService> logger) => _logger = logger;

    /// <summary>Processes <paramref name="audioPath"/> in place per the enabled flags. No-op if both are off.</summary>
    public async Task ProcessInPlaceAsync(string audioPath, bool noiseSuppression, bool enhanceVoice,
        double noiseStrength = 0.7, CancellationToken ct = default)
    {
        if ((!noiseSuppression && !enhanceVoice) || !File.Exists(audioPath)) return;
        try
        {
            var (samples, rate) = await WavAudioIo.ExtractMonoAsync(audioPath, 48000, ct).ConfigureAwait(false);
            if (samples.Length == 0) return;

            if (noiseSuppression) samples = AudioDsp.NoiseGate(samples, rate, noiseStrength);
            if (enhanceVoice) samples = AudioDsp.Enhance(new[] { samples }, rate)[0];

            await WavAudioIo.EncodeMonoToM4aAsync(samples, rate, audioPath, ct).ConfigureAwait(false);
            _logger.LogInformation("Audio cleanup applied (noise={Noise}, enhance={Enhance})", noiseSuppression, enhanceVoice);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Audio cleanup failed; keeping the original narration.");
        }
    }
}
