namespace DemoTape.Domain.Ai;

/// <summary>A speech-to-text provider preset (OpenAI-compatible transcription API).</summary>
public sealed record AiProvider(string Name, string BaseUrl, string Model, string KeysUrl);

/// <summary>
/// Catalog of AI providers and the key-store account names. Mirrors the macOS AI settings:
/// captions use an OpenAI-compatible Whisper endpoint, voiceover uses ElevenLabs, avatar uses HeyGen.
/// </summary>
public static class AiCatalog
{
    public static readonly IReadOnlyList<AiProvider> SttProviders = new[]
    {
        new AiProvider("OpenAI", "https://api.openai.com/v1", "whisper-1", "https://platform.openai.com/api-keys"),
        new AiProvider("Groq", "https://api.groq.com/openai/v1", "whisper-large-v3", "https://console.groq.com/keys"),
        new AiProvider("Custom", "", "", ""),
    };

    public const string ElevenKeysUrl = "https://elevenlabs.io/app/settings/api-keys";
    public const string HeyGenKeysUrl = "https://app.heygen.com/settings";
}

/// <summary>Key-store account identifiers for the BYO-key secrets.</summary>
public static class KeyAccounts
{
    public const string Stt = "ai/stt";
    public const string ElevenLabs = "ai/elevenlabs";
    public const string HeyGen = "ai/heygen";
}
