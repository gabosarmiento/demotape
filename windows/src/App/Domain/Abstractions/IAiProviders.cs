using DemoTape.Domain.Ai;

namespace DemoTape.Domain.Abstractions;

/// <summary>Transcribes an audio file via an OpenAI-compatible speech-to-text API (BYO key).</summary>
public interface ITranscriptionProvider
{
    Task<IReadOnlyList<CaptionCue>> TranscribeAsync(
        string audioPath, string baseUrl, string model, string apiKey, string language, CancellationToken ct = default);
}

/// <summary>Text-to-speech voices + synthesis (ElevenLabs; BYO key).</summary>
public interface IVoiceProvider
{
    Task<IReadOnlyList<Voice>> ListVoicesAsync(string apiKey, CancellationToken ct = default);

    /// <summary>Synthesizes <paramref name="text"/> and returns a temp audio file path (MP3).</summary>
    Task<string> SynthesizeAsync(string text, string voiceId, string model, string apiKey, CancellationToken ct = default);
}
