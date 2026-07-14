using System.Text.Json;

namespace DemoTape.Domain.Ai;

/// <summary>A selectable avatar from the provider's library.</summary>
public sealed record AvatarDescriptor(string Id, string Name, string? PreviewImageUrl, bool IsPremium, string? Gender);

/// <summary>Where the avatar comes from.</summary>
public abstract record AvatarSource
{
    public sealed record Library(string AvatarId) : AvatarSource;
    public sealed record Photo(string ImageAssetId) : AvatarSource;
}

public enum AvatarQuality { P720, P1080, P4k }

/// <summary>A request to generate an avatar video from already-uploaded narration audio.</summary>
public sealed record AvatarGenerationRequest(
    AvatarSource Source,
    string AudioAssetId,
    string BackgroundHex = "#00B140",
    AvatarQuality Resolution = AvatarQuality.P720,
    string? MotionPrompt = null,
    string? Engine = null);

public sealed record AvatarJob(string Id);

public abstract record AvatarJobStatus
{
    public sealed record Pending : AvatarJobStatus;
    public sealed record Processing : AvatarJobStatus;
    public sealed record Completed(string ResultUrl) : AvatarJobStatus;
    public sealed record Failed(string Message) : AvatarJobStatus;
}

/// <summary>
/// Pure HeyGen request/response encoding — no network, fully testable. Verified against the v3
/// Videos / v3 Assets / v2 Avatars / v1 status shapes (ported from the macOS provider).
/// </summary>
public static class HeyGenApi
{
    public static string ResolutionValue(AvatarQuality q) => q switch
    {
        AvatarQuality.P720 => "720p", AvatarQuality.P1080 => "1080p", _ => "4k"
    };

    public static string EncodeCreateBody(AvatarGenerationRequest r)
    {
        var body = new Dictionary<string, object?>
        {
            ["audio_asset_id"] = r.AudioAssetId,
            ["background"] = new Dictionary<string, object?> { ["type"] = "color", ["value"] = r.BackgroundHex },
            ["output_format"] = "mp4",
            ["resolution"] = ResolutionValue(r.Resolution),
        };
        switch (r.Source)
        {
            case AvatarSource.Library lib:
                body["type"] = "avatar";
                body["avatar_id"] = lib.AvatarId;
                if (!string.IsNullOrEmpty(r.Engine)) body["engine"] = new Dictionary<string, object?> { ["type"] = r.Engine };
                break;
            case AvatarSource.Photo photo:
                body["type"] = "image";
                body["image"] = new Dictionary<string, object?> { ["type"] = "asset_id", ["asset_id"] = photo.ImageAssetId };
                break;
        }
        if (!string.IsNullOrWhiteSpace(r.MotionPrompt)) body["motion_prompt"] = r.MotionPrompt!.Trim();
        return JsonSerializer.Serialize(body);
    }

    public static IReadOnlyList<AvatarDescriptor> ParseAvatars(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var list = new List<AvatarDescriptor>();
        if (doc.RootElement.TryGetProperty("data", out var data) &&
            data.TryGetProperty("avatars", out var avatars) && avatars.ValueKind == JsonValueKind.Array)
        {
            foreach (var a in avatars.EnumerateArray())
            {
                string id = Str(a, "avatar_id");
                if (id.Length == 0) continue;
                list.Add(new AvatarDescriptor(
                    id, Str(a, "avatar_name") is { Length: > 0 } n ? n : id,
                    a.TryGetProperty("preview_image_url", out var p) ? p.GetString() : null,
                    a.TryGetProperty("premium", out var pr) && pr.ValueKind == JsonValueKind.True,
                    a.TryGetProperty("gender", out var g) ? g.GetString() : null));
            }
        }
        return list;
    }

    public static string? ParseAssetId(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.TryGetProperty("data", out var d) ? NullIfEmpty(Str(d, "asset_id")) : null;
    }

    public static string? ParseVideoId(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.TryGetProperty("data", out var d) ? NullIfEmpty(Str(d, "video_id")) : null;
    }

    public static AvatarJobStatus ParseStatus(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.TryGetProperty("data", out var d) && d.ValueKind == JsonValueKind.Object)
        {
            var status = Str(d, "status").ToLowerInvariant();
            switch (status)
            {
                case "completed" or "success" or "done":
                    var url = Str(d, "video_url");
                    return url.Length > 0 ? new AvatarJobStatus.Completed(url) : new AvatarJobStatus.Failed("completed but no video_url");
                case "failed" or "error":
                    string msg = d.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.Object ? Str(e, "message") : "generation failed";
                    return new AvatarJobStatus.Failed(msg.Length > 0 ? msg : "generation failed");
                case "pending" or "waiting" or "queued":
                    return new AvatarJobStatus.Pending();
                default:
                    return new AvatarJobStatus.Processing();
            }
        }
        return new AvatarJobStatus.Failed(Str(root, "message") is { Length: > 0 } m ? m : "unknown status response");
    }

    public static string ParseErrorMessage(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.Object)
            {
                var m = Str(e, "message");
                var param = Str(e, "param");
                if (m.Length > 0) return param.Length > 0 ? $"{m} ({param})" : m;
            }
            var top = Str(root, "message");
            if (top.Length > 0) return top;
        }
        catch { }
        return json.Length > 200 ? json[..200] : json;
    }

    private static string Str(JsonElement el, string prop) => el.TryGetProperty(prop, out var v) ? v.GetString() ?? "" : "";
    private static string? NullIfEmpty(string s) => string.IsNullOrEmpty(s) ? null : s;
}
