using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Publishing;
using Microsoft.Extensions.Logging;

namespace DemoTape.Services;

/// <summary>
/// Orchestrates the Web Publish flow — the first complete vertical slice. Given a styled
/// source MP4 and a set of quality tiers, it produces a "<name>-web" folder containing an
/// MP4 per tier, a poster, a responsive <c>embed.html</c>, and a README.
///
/// Ported from the macOS <c>WebPublishController.publish</c>. All file I/O uses plain .NET so
/// this is testable with a fake <see cref="IVideoTranscoder"/> against a temp directory;
/// tier planning / embed generation live in <see cref="WebPublishPlanner"/> (Domain).
/// </summary>
public sealed class WebPublishService
{
    private readonly IVideoTranscoder _transcoder;
    private readonly ILogger<WebPublishService> _logger;

    public WebPublishService(IVideoTranscoder transcoder, ILogger<WebPublishService>? logger = null)
    {
        _transcoder = transcoder ?? throw new ArgumentNullException(nameof(transcoder));
        _logger = logger ?? Microsoft.Extensions.Logging.Abstractions.NullLogger<WebPublishService>.Instance;
    }

    /// <summary>
    /// Publishes <paramref name="sourcePath"/> to the selected <paramref name="heights"/>.
    /// Returns the created web folder and its files, or throws on transcode failure.
    /// </summary>
    public async Task<WebPublishResult> PublishAsync(
        string sourcePath,
        IReadOnlyCollection<int> heights,
        IProgress<double>? progress = null,
        CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(sourcePath))
            throw new ArgumentException("Source path is required.", nameof(sourcePath));
        if (!File.Exists(sourcePath))
            throw new FileNotFoundException("Styled recording not found.", sourcePath);
        if (heights.Count == 0)
            throw new ArgumentException("Select at least one quality tier.", nameof(heights));

        var sorted = heights.Distinct().OrderBy(h => h).ToList();
        var sourceDir = Path.GetDirectoryName(sourcePath)!;
        var baseName = Path.GetFileNameWithoutExtension(sourcePath);
        var folderName = WebPublishPlanner.WebFolderName(baseName);
        var folder = Path.Combine(sourceDir, folderName);
        Directory.CreateDirectory(folder);

        var files = new List<string>();
        int done = 0;

        foreach (var h in sorted)
        {
            ct.ThrowIfCancellationRequested();
            var outPath = Path.Combine(folder, WebPublishPlanner.TierFileName(h));
            _logger.LogInformation("Web publish: transcoding {Height}p -> {Path}", h, outPath);

            var tierProgress = progress is null
                ? null
                : new Progress<double>(p => progress.Report((done + p) / sorted.Count));

            await _transcoder.TranscodeAsync(sourcePath, outPath, h, tierProgress, ct).ConfigureAwait(false);
            files.Add(outPath);
            done++;
            progress?.Report((double)done / sorted.Count);
        }

        // Poster from a representative frame.
        var posterPath = Path.Combine(folder, "poster.jpg");
        await _transcoder.SavePosterAsync(sourcePath, posterPath, sorted.Max(), ct).ConfigureAwait(false);
        files.Add(posterPath);

        // Responsive embed + README.
        var embedPath = Path.Combine(folder, "embed.html");
        await File.WriteAllTextAsync(embedPath, WebPublishPlanner.BuildEmbedHtml(sorted), ct).ConfigureAwait(false);
        files.Add(embedPath);

        var readmePath = Path.Combine(folder, "README.txt");
        await File.WriteAllTextAsync(readmePath, WebPublishPlanner.BuildReadme(sorted), ct).ConfigureAwait(false);
        files.Add(readmePath);

        _logger.LogInformation("Web publish complete: {Folder} ({Count} files)", folder, files.Count);
        return new WebPublishResult(folder, files);
    }
}
