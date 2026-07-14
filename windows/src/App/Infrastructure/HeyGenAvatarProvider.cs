using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Ai;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// HeyGen implementation of <see cref="IAvatarProvider"/> (v3 Videos / v3 Assets / v2 Avatars /
/// v1 status). The API key is only ever sent in the <c>x-api-key</c> header, never logged. Request
/// bodies / responses are built and parsed by the pure <see cref="HeyGenApi"/> (unit-tested).
/// </summary>
public sealed class HeyGenAvatarProvider : IAvatarProvider
{
    private const string AvatarsUrl = "https://api.heygen.com/v2/avatars";
    private const string AssetsUrl = "https://api.heygen.com/v3/assets";
    private const string VideosUrl = "https://api.heygen.com/v3/videos";
    private static string StatusUrl(string id) => $"https://api.heygen.com/v1/video_status.get?video_id={id}";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };

    public async Task<IReadOnlyList<AvatarDescriptor>> ListAvatarsAsync(string apiKey, CancellationToken ct = default)
    {
        var body = await GetAsync(AvatarsUrl, apiKey, ct);
        return HeyGenApi.ParseAvatars(body);
    }

    public async Task<string> UploadAssetAsync(string filePath, string apiKey, CancellationToken ct = default)
    {
        using var form = new MultipartFormDataContent();
        var bytes = await File.ReadAllBytesAsync(filePath, ct);
        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue(MimeFor(filePath));
        form.Add(content, "file", Path.GetFileName(filePath));

        using var req = new HttpRequestMessage(HttpMethod.Post, AssetsUrl) { Content = form };
        req.Headers.TryAddWithoutValidation("x-api-key", apiKey);
        req.Headers.TryAddWithoutValidation("Idempotency-Key", Guid.NewGuid().ToString());
        var body = await SendAsync(req, ct);
        return HeyGenApi.ParseAssetId(body) ?? throw new InvalidOperationException("HeyGen: no asset_id in upload response.");
    }

    public async Task<AvatarJob> CreateVideoAsync(AvatarGenerationRequest request, string idempotencyKey, string apiKey, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, VideosUrl)
        {
            Content = new StringContent(HeyGenApi.EncodeCreateBody(request), Encoding.UTF8, "application/json"),
        };
        req.Headers.TryAddWithoutValidation("x-api-key", apiKey);
        req.Headers.TryAddWithoutValidation("Idempotency-Key", idempotencyKey);
        var body = await SendAsync(req, ct);
        return new AvatarJob(HeyGenApi.ParseVideoId(body) ?? throw new InvalidOperationException("HeyGen: no video_id in create response."));
    }

    public async Task<AvatarJobStatus> JobStatusAsync(string jobId, string apiKey, CancellationToken ct = default)
        => HeyGenApi.ParseStatus(await GetAsync(StatusUrl(jobId), apiKey, ct));

    public async Task DownloadAsync(string resultUrl, string destinationPath, CancellationToken ct = default)
    {
        using var resp = await Http.GetAsync(resultUrl, ct);
        resp.EnsureSuccessStatusCode();
        await using var fs = File.Create(destinationPath);
        await resp.Content.CopyToAsync(fs, ct);
    }

    private static async Task<string> GetAsync(string url, string apiKey, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("x-api-key", apiKey);
        return await SendAsync(req, ct);
    }

    private static async Task<string> SendAsync(HttpRequestMessage req, CancellationToken ct)
    {
        using var resp = await Http.SendAsync(req, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"HeyGen error (HTTP {(int)resp.StatusCode}): {HeyGenApi.ParseErrorMessage(body)}");
        return body;
    }

    private static string MimeFor(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".mp3" => "audio/mpeg", ".wav" => "audio/wav", ".m4a" => "audio/mp4",
        ".png" => "image/png", ".jpg" or ".jpeg" => "image/jpeg", _ => "application/octet-stream",
    };
}
