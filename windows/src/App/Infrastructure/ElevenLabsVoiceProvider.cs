using System.Net.Http;
using System.Text;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Ai;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// ElevenLabs text-to-speech: list voices and synthesize a script to MP3. Mirrors the macOS
/// <c>Voiceover</c> networking. Bring-your-own-key.
/// </summary>
public sealed class ElevenLabsVoiceProvider : IVoiceProvider
{
    private const string Base = "https://api.elevenlabs.io/v1";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(5) };

    public async Task<IReadOnlyList<Voice>> ListVoicesAsync(string apiKey, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(apiKey)) throw new InvalidOperationException("No ElevenLabs API key configured.");
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{Base}/voices");
        req.Headers.TryAddWithoutValidation("xi-api-key", apiKey);
        using var resp = await Http.SendAsync(req, ct).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"ElevenLabs API error (HTTP {(int)resp.StatusCode}).");
        return VoiceoverPlanner.ParseVoices(body);
    }

    public async Task<string> SynthesizeAsync(string text, string voiceId, string model, string apiKey, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(apiKey)) throw new InvalidOperationException("No ElevenLabs API key configured.");
        if (string.IsNullOrWhiteSpace(text)) throw new InvalidOperationException("The script is empty.");

        using var req = new HttpRequestMessage(HttpMethod.Post, $"{Base}/text-to-speech/{voiceId}");
        req.Headers.TryAddWithoutValidation("xi-api-key", apiKey);
        req.Headers.TryAddWithoutValidation("Accept", "audio/mpeg");
        var payload = System.Text.Json.JsonSerializer.Serialize(new
        {
            text,
            model_id = string.IsNullOrWhiteSpace(model) ? "eleven_multilingual_v2" : model,
        });
        req.Content = new StringContent(payload, Encoding.UTF8, "application/json");

        using var resp = await Http.SendAsync(req, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            var err = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            throw new InvalidOperationException($"Voice synthesis failed (HTTP {(int)resp.StatusCode}): {(err.Length > 300 ? err[..300] : err)}");
        }

        var outPath = Path.Combine(Path.GetTempPath(), $"demotape-vo-{Guid.NewGuid():N}.mp3");
        await using var fs = File.Create(outPath);
        await resp.Content.CopyToAsync(fs, ct).ConfigureAwait(false);
        return outPath;
    }
}
