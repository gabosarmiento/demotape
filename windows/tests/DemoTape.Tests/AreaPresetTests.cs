using DemoTape.Domain;
using Xunit;

namespace DemoTape.Tests;

public class AreaPresetTests
{
    [Fact]
    public void AllPresets_Defined()
    {
        Assert.Equal(5, AreaPreset.All.Count);
        Assert.Contains(AreaPreset.All, p => p.Name.Contains("Full HD"));
        Assert.Contains(AreaPreset.All, p => p.Name.Contains("720p"));
        Assert.Contains(AreaPreset.All, p => p.Name.Contains("4:3"));
        Assert.Contains(AreaPreset.All, p => p.Name.Contains("Square"));
        Assert.Contains(AreaPreset.All, p => p.Name.Contains("Portrait"));
    }

    [Fact]
    public void CenteredRect_FitsWithinScreen()
    {
        var preset = new AreaPreset("Test", 1280, 720);
        var (x, y, w, h) = preset.CenteredRect(0.5, 0.5, 1920, 1080);

        // Rect must stay within [0, 1] in both dimensions.
        Assert.True(x >= 0.0 && x <= 1.0, $"x={x}");
        Assert.True(y >= 0.0 && y <= 1.0, $"y={y}");
        Assert.True(x + w <= 1.0 + 1e-9, $"x+w={x + w}");
        Assert.True(y + h <= 1.0 + 1e-9, $"y+h={y + h}");
    }

    [Fact]
    public void CenteredRect_CenteredOnScreen()
    {
        var preset = new AreaPreset("Test", 1280, 720);
        var (x, y, w, h) = preset.CenteredRect(0.5, 0.5, 1920, 1080);

        // With a 1280x720 preset on a 1920x1080 screen, should be perfectly centered.
        Assert.Equal(1280.0 / 1920, w, precision: 5);
        Assert.Equal(720.0  / 1080, h, precision: 5);
        Assert.Equal((1.0 - w) / 2, x, precision: 5);
        Assert.Equal((1.0 - h) / 2, y, precision: 5);
    }

    [Fact]
    public void CenteredRect_ClampedWhenNearEdge()
    {
        // Center is at 0,0 (top-left corner) — rect should be clamped so X,Y >= 0.
        var preset = new AreaPreset("Test", 1280, 720);
        var (x, y, w, h) = preset.CenteredRect(0.0, 0.0, 1920, 1080);

        Assert.Equal(0.0, x);
        Assert.Equal(0.0, y);
        // Width and height should still be the preset fraction of the screen.
        Assert.Equal(1280.0 / 1920, w, precision: 5);
        Assert.Equal(720.0  / 1080, h, precision: 5);
    }

    [Fact]
    public void CenteredRect_ClampedWhenBottomRight()
    {
        var preset = new AreaPreset("Test", 1280, 720);
        var (x, y, w, h) = preset.CenteredRect(1.0, 1.0, 1920, 1080);

        // Rect must not exceed 1 in either dimension.
        Assert.True(x + w <= 1.0 + 1e-9, $"x+w={x + w}");
        Assert.True(y + h <= 1.0 + 1e-9, $"y+h={y + h}");
    }

    [Fact]
    public void CenteredRect_PresetLargerThanScreen_ClampedTo1()
    {
        // A 1920×1080 preset on a 1280×720 screen — the normalized size exceeds 1.0 and must be clamped.
        var preset = new AreaPreset("Test", 1920, 1080);
        var (x, y, w, h) = preset.CenteredRect(0.5, 0.5, 1280, 720);

        Assert.Equal(0.0, x);
        Assert.Equal(0.0, y);
        Assert.Equal(1.0, w);
        Assert.Equal(1.0, h);
    }
}
