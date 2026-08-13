using DemoTape.Domain;
using Xunit;

namespace DemoTape.Tests;

public class RecordingLayoutTests : IDisposable
{
    private readonly string _dir;

    public RecordingLayoutTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "demotape-layout-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private string Touch(string name)
    {
        var path = Path.Combine(_dir, name);
        File.WriteAllText(path, "x");
        return path;
    }

    [Fact]
    public void NullOrMissingFolder_ReturnsNull()
    {
        Assert.Null(RecordingLayout.LatestSource(null));
        Assert.Null(RecordingLayout.LatestSource(""));
        Assert.Null(RecordingLayout.LatestSource(@"C:\definitely\does\not\exist\folder"));
    }

    [Fact]
    public void EmptyFolder_ReturnsNull()
    {
        Assert.Null(RecordingLayout.LatestSource(_dir));
    }

    [Fact]
    public void OnlyRaw_ReturnsRaw()
    {
        var raw = Touch("rec.mp4");
        Assert.Equal(raw, RecordingLayout.LatestSource(_dir));
    }

    [Fact]
    public void RawAndStyled_ReturnsStyled()
    {
        Touch("rec.mp4");
        var styled = Touch("rec.styled.mp4");
        Assert.Equal(styled, RecordingLayout.LatestSource(_dir));
    }

    [Fact]
    public void StyledAndCaptioned_ReturnsCaptioned()
    {
        Touch("rec.mp4");
        Touch("rec.styled.mp4");
        var captioned = Touch("rec.captioned.mp4");
        Assert.Equal(captioned, RecordingLayout.LatestSource(_dir));
    }

    [Fact]
    public void AllDerivatives_ReturnsCaptioned()
    {
        Touch("rec.mp4");
        Touch("rec.styled.mp4");
        Touch("rec.avatar.mp4");
        Touch("rec.voiceover.mp4");
        Touch("rec.tight.mp4");
        var captioned = Touch("rec.captioned.mp4");
        Assert.Equal(captioned, RecordingLayout.LatestSource(_dir));
    }

    [Fact]
    public void PriorityOrder_TightBeatsStyled()
    {
        Touch("rec.styled.mp4");
        var tight = Touch("rec.tight.mp4");
        Assert.Equal(tight, RecordingLayout.LatestSource(_dir));
    }

    [Fact]
    public void CamSidecar_ExcludedFromRawFallback()
    {
        Touch("rec.cam.mp4");   // sidecar, must be ignored
        var raw = Touch("rec.mp4");
        Assert.Equal(raw, RecordingLayout.LatestSource(_dir));
    }

    [Fact]
    public void CamSidecarOnly_ReturnsNull()
    {
        Touch("rec.cam.mp4");
        Assert.Null(RecordingLayout.LatestSource(_dir));
    }

    [Fact]
    public void MultipleRaw_ReturnsNewest()
    {
        var old = Touch("rec1.mp4");
        // Make sure the second file has a later modification time.
        File.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddSeconds(-10));
        var newest = Touch("rec2.mp4");
        Assert.Equal(newest, RecordingLayout.LatestSource(_dir));
    }
}
