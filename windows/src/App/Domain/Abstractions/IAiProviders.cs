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

/// <summary>Avatar-video backend (HeyGen); BYO key. Provider-agnostic so a second vendor can slot in.</summary>
public interface IAvatarProvider
{
    Task<IReadOnlyList<AvatarDescriptor>> ListAvatarsAsync(string apiKey, CancellationToken ct = default);
    Task<string> UploadAssetAsync(string filePath, string apiKey, CancellationToken ct = default);
    Task<AvatarJob> CreateVideoAsync(AvatarGenerationRequest request, string idempotencyKey, string apiKey, CancellationToken ct = default);
    Task<AvatarJobStatus> JobStatusAsync(string jobId, string apiKey, CancellationToken ct = default);
    Task DownloadAsync(string resultUrl, string destinationPath, CancellationToken ct = default);
}
