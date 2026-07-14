using DemoTape.Services;
using Xunit;

namespace DemoTape.Tests;

public class WebPublishServiceTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _source;

    public WebPublishServiceTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "demotape-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempDir);
        _source = Path.Combine(_tempDir, "DemoTape 2026-07-08.styled.mp4");
        File.WriteAllText(_source, "styled-master");
    }

    [Fact]
    public async Task PublishAsync_WritesTiers_Poster_Embed_Readme()
    {
        var transcoder = new FakeTranscoder();
        var svc = new WebPublishService(transcoder);

        var result = await svc.PublishAsync(_source, new[] { 540, 720 });

        var folder = result.OutputFolder;
        Assert.EndsWith("DemoTape 2026-07-08-web", folder);
        Assert.True(File.Exists(Path.Combine(folder, "demo-540p.mp4")));
        Assert.True(File.Exists(Path.Combine(folder, "demo-720p.mp4")));
        Assert.True(File.Exists(Path.Combine(folder, "poster.jpg")));
        Assert.True(File.Exists(Path.Combine(folder, "embed.html")));
        Assert.True(File.Exists(Path.Combine(folder, "README.txt")));

        Assert.Equal(2, transcoder.Calls.Count);
        Assert.Equal(1, transcoder.PosterCalls);

        var embed = await File.ReadAllTextAsync(Path.Combine(folder, "embed.html"));
        Assert.Contains("demo-720p.mp4", embed);
    }

    [Fact]
    public async Task PublishAsync_ReportsProgressToCompletion()
    {
        var svc = new WebPublishService(new FakeTranscoder());
        double last = 0;
        var progress = new Progress<double>(p => last = p);

        await svc.PublishAsync(_source, new[] { 360, 540 }, progress);
        // Give the Progress<T> synchronization context a moment to flush callbacks.
        await Task.Delay(20);
        Assert.True(last >= 0.99, $"final progress was {last}");
    }

    [Fact]
    public async Task PublishAsync_Throws_WhenNoTiersSelected()
    {
        var svc = new WebPublishService(new FakeTranscoder());
        await Assert.ThrowsAsync<ArgumentException>(() => svc.PublishAsync(_source, Array.Empty<int>()));
    }

    [Fact]
    public async Task PublishAsync_Throws_WhenSourceMissing()
    {
        var svc = new WebPublishService(new FakeTranscoder());
        await Assert.ThrowsAsync<FileNotFoundException>(
            () => svc.PublishAsync(Path.Combine(_tempDir, "missing.mp4"), new[] { 540 }));
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { /* best effort */ }
    }
}
