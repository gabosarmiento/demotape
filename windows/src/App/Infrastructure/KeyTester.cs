using System.Net;
using System.Net.Http;

namespace DemoTape.App.Infrastructure;

/// <summary>Outcome of validating an API key against its provider.</summary>
public enum KeyTestKind { Ok, Invalid, Failed }

public readonly record struct KeyTestResult(KeyTestKind Kind, string Message);

/// <summary>
/// Lightweight, read-only validation of BYO API keys — mirrors the macOS KeyTester. Each check hits
/// a cheap authenticated endpoint and maps the status to Ok / Invalid (bad key) / Failed (network).
/// </summary>
public sealed class KeyTester
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    /// <summary>Validates an OpenAI-compatible transcription key by listing models.</summary>
    public async Task<KeyTestResult> TestSttAsync(string baseUrl, string apiKey)
    {
        if (string.IsNullOrWhiteSpace(apiKey)) return new(KeyTestKind.Invalid, "Enter a key first.");
        var b = string.IsNullOrWhiteSpace(baseUrl) ? "https://api.openai.com/v1" : baseUrl.TrimEnd('/');
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{b}/models");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {apiKey}");
        return await SendAsync(req, "Key looks valid.");
    }

    /// <summary>Validates an ElevenLabs key via the /user endpoint.</summary>
    public async Task<KeyTestResult> TestElevenLabsAsync(string apiKey)
    {
        if (string.IsNullOrWhiteSpace(apiKey)) return new(KeyTestKind.Invalid, "Enter a key first.");
        using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.elevenlabs.io/v1/user");
        req.Headers.TryAddWithoutValidation("xi-api-key", apiKey);
        return await SendAsync(req, "Key looks valid.");
    }

    /// <summary>Validates a HeyGen key by listing avatars (v2).</summary>
    public async Task<KeyTestResult> TestHeyGenAsync(string apiKey)
    {
        if (string.IsNullOrWhiteSpace(apiKey)) return new(KeyTestKind.Invalid, "Enter a key first.");
        using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.heygen.com/v2/avatars");
        req.Headers.TryAddWithoutValidation("X-Api-Key", apiKey);
        return await SendAsync(req, "Key looks valid.");
    }

    private static async Task<KeyTestResult> SendAsync(HttpRequestMessage req, string okMessage)
    {
        try
        {
            using var resp = await Http.SendAsync(req);
            if (resp.IsSuccessStatusCode) return new(KeyTestKind.Ok, okMessage);
            if (resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                return new(KeyTestKind.Invalid, "Key was rejected (unauthorized).");
            return new(KeyTestKind.Failed, $"Unexpected response: {(int)resp.StatusCode}.");
        }
        catch (Exception ex)
        {
            return new(KeyTestKind.Failed, "Couldn't reach the provider: " + ex.Message);
        }
    }
}
