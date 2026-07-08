using System.Text.Json;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Models;
using Microsoft.Extensions.Logging;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Enumerates recordings in the output directory. Mirrors the macOS
/// <c>WebPublishController.latestStyled()</c> selection (newest <c>*.styled.mp4</c>) and reads
/// the <c>*.events.json</c> sidecar for the auto-editor.
/// </summary>
public sealed class FileRecordingStore : IRecordingStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly IPathService _paths;
    private readonly IVideoTranscoder _transcoder;
    private readonly ILogger<FileRecordingStore> _logger;

    public FileRecordingStore(IPathService paths, IVideoTranscoder transcoder, ILogger<FileRecordingStore> logger)
    {
        _paths = paths;
        _transcoder = transcoder;
        _logger = logger;
    }

    public IReadOnlyList<RecordingItem> ListStyledRecordings()
    {
        var dir = _paths.OutputDirectory;
        if (!Directory.Exists(dir)) return Array.Empty<RecordingItem>();

        return Directory.EnumerateFiles(dir, "*.styled.mp4")
            .Select(p => new FileInfo(p))
            .OrderByDescending(f => f.LastWriteTimeUtc)
            .Select(f => new RecordingItem(
                f.FullName,
                f.Name,
                new DateTimeOffset(f.LastWriteTimeUtc, TimeSpan.Zero),
                SafeDuration(f.FullName)))
            .ToList();
    }

    public RecordingItem? LatestStyled() => ListStyledRecordings().FirstOrDefault();

    public RecordingMetadata? LoadMetadata(string recordingPath)
    {
        try
        {
            // "…styled.mp4" or "….mp4" → "….events.json"
            var withoutExt = StripKnownExtensions(recordingPath);
            var sidecar = withoutExt + ".events.json";
            if (!File.Exists(sidecar)) return null;
            var json = File.ReadAllText(sidecar);
            return JsonSerializer.Deserialize<RecordingMetadata>(json, Options);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to read sidecar for {Path}", recordingPath);
            return null;
        }
    }

    private double SafeDuration(string path)
    {
        try { return _transcoder.GetDurationSecondsAsync(path).GetAwaiter().GetResult(); }
        catch { return 0; }
    }

    private static string StripKnownExtensions(string path)
    {
        var s = path;
        if (s.EndsWith(".styled.mp4", StringComparison.OrdinalIgnoreCase))
            return s[..^".styled.mp4".Length];
        return Path.Combine(Path.GetDirectoryName(s) ?? "", Path.GetFileNameWithoutExtension(s));
    }
}
