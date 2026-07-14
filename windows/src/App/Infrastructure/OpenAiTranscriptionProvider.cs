using System.Net.Http;
using System.Net.Http.Headers;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Ai;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Transcribes audio via an OpenAI-compatible <c>/audio/transcriptions</c> endpoint (OpenAI, Groq,
/// or any compatible server), requesting <c>verbose_json</c> for timestamped segments. Mirrors the
/// macOS <c>Captions.transcribe</c>. Bring-your-own-key — no calls unless the user runs captions.
/// </summary>
public sealed class OpenAiTranscriptionProvider : ITranscriptionProvider
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(5) };

    public async Task<IReadOnlyList<CaptionCue>> TranscribeAsync(
        string audioPath, string baseUrl, string model, string apiKey, string language, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(apiKey)) throw new InvalidOperationException("No API key configured for captions.");
        var endpoint = Endpoint(baseUrl) ?? throw new InvalidOperationException("Invalid transcription base URL.");

        using var form = new MultipartFormDataContent();
        var audioBytes = await File.ReadAllBytesAsync(audioPath, ct).ConfigureAwait(false);
        var fileContent = new ByteArrayContent(audioBytes);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/m4a");
        form.Add(fileContent, "file", Path.GetFileName(audioPath));
        form.Add(new StringContent(string.IsNullOrWhiteSpace(model) ? "whisper-1" : model), "model");
        form.Add(new StringContent("verbose_json"), "response_format");
        if (!string.IsNullOrWhiteSpace(language)) form.Add(new StringContent(language), "language");

        using var req = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = form };
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {apiKey}");

        using var resp = await Http.SendAsync(req, ct).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Transcription API error (HTTP {(int)resp.StatusCode}): {Trim(body)}");

        return CaptionFormats.ParseVerboseJson(body);
    }

    private static string? Endpoint(string baseUrl)
    {
        var b = (baseUrl ?? "").Trim().TrimEnd('/');
        return string.IsNullOrEmpty(b) ? null : b + "/audio/transcriptions";
    }

    private static string Trim(string s) => s.Length > 400 ? s[..400] : s;
}
