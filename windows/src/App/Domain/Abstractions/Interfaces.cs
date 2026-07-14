using DemoTape.Domain.Models;
using DemoTape.Domain.Settings;

namespace DemoTape.Domain.Abstractions;

/// <summary>Persists and loads <see cref="AppSettings"/> (JSON file in %LOCALAPPDATA%).</summary>
public interface ISettingsStore
{
    AppSettings Load();
    void Save(AppSettings settings);
}

/// <summary>Resolves filesystem locations (recordings folder, logs, settings).</summary>
public interface IPathService
{
    /// <summary>The recordings output directory (<c>%USERPROFILE%\Videos\DemoTape</c>), created if missing.</summary>
    string OutputDirectory { get; }

    /// <summary>Per-user app-data directory (<c>%LOCALAPPDATA%\DemoTape</c>), created if missing.</summary>
    string AppDataDirectory { get; }
}

/// <summary>A styled recording available for web publishing.</summary>
public sealed record RecordingItem(string StyledPath, string DisplayName, DateTimeOffset ModifiedAt, double DurationSeconds);

/// <summary>Enumerates recordings in the output directory and reads their sidecars.</summary>
public interface IRecordingStore
{
    /// <summary>All <c>*.styled.mp4</c> recordings, newest first.</summary>
    IReadOnlyList<RecordingItem> ListStyledRecordings();

    /// <summary>The most recent styled recording, or null if none.</summary>
    RecordingItem? LatestStyled();

    /// <summary>Loads the event-timeline sidecar for a raw/styled recording, or null if absent.</summary>
    RecordingMetadata? LoadMetadata(string recordingPath);
}

/// <summary>Downscales a styled MP4 into a web-ready tier (H.264 + AAC, faststart).</summary>
public interface IVideoTranscoder
{
    /// <summary>Transcodes <paramref name="inputPath"/> to <paramref name="outputPath"/> at the given height (px).</summary>
    Task TranscodeAsync(string inputPath, string outputPath, int height, IProgress<double>? progress = null, CancellationToken ct = default);

    /// <summary>Writes a poster JPEG from a representative frame.</summary>
    Task SavePosterAsync(string inputPath, string outputPath, int maxHeight, CancellationToken ct = default);

    /// <summary>Duration of a media file in seconds.</summary>
    Task<double> GetDurationSecondsAsync(string inputPath, CancellationToken ct = default);
}

/// <summary>Result of a web-publish run.</summary>
public sealed record WebPublishResult(string OutputFolder, IReadOnlyList<string> Files);

/// <summary>Encodes a video into a looping animated GIF (for README/social embeds).</summary>
public interface IGifEncoder
{
    Task EncodeAsync(string videoPath, string outPath, int maxWidth = 480, double fps = 10,
        double maxDuration = 15, CancellationToken ct = default);
}
