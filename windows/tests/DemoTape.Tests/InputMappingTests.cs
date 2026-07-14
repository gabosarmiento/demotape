using DemoTape.Domain.Input;
using Xunit;
using static DemoTape.Domain.Input.InputMapping;

namespace DemoTape.Tests;

public class InputMappingTests
{
    [Fact]
    public void Normalize_MapsPointWithinRegion()
    {
        var (x, y) = Normalize(px: 1000, py: 500, regionX: 500, regionY: 250, regionW: 1000, regionH: 500);
        Assert.Equal(0.5, x, 6);
        Assert.Equal(0.5, y, 6);
    }

    [Fact]
    public void Normalize_ClampsOutsideRegion()
    {
        var (x, y) = Normalize(px: 100, py: 100, regionX: 500, regionY: 250, regionW: 1000, regionH: 500);
        Assert.Equal(0, x, 6);
        Assert.Equal(0, y, 6);
    }

    [Fact]
    public void Normalize_ZeroRegion_ReturnsOrigin()
    {
        var (x, y) = Normalize(1, 1, 0, 0, 0, 0);
        Assert.Equal(0, x);
        Assert.Equal(0, y);
    }

    [Fact]
    public void Modifiers_MapInCanonicalOrder()
    {
        var mods = Modifiers(Mod.Ctrl | Mod.Shift);
        Assert.Equal(new[] { "ctrl", "shift" }, mods);
    }

    [Theory]
    [InlineData(Mod.Ctrl, true)]
    [InlineData(Mod.Alt, true)]
    [InlineData(Mod.Win, true)]
    [InlineData(Mod.Shift, false)]
    [InlineData(Mod.None, false)]
    public void IsShortcut_RequiresCtrlAltOrWin(Mod mods, bool expected)
    {
        Assert.Equal(expected, IsShortcut(mods));
    }

    [Theory]
    [InlineData(true, false, "left")]
    [InlineData(false, true, "right")]
    [InlineData(false, false, "other")]
    public void ButtonName_Maps(bool left, bool right, string expected)
    {
        Assert.Equal(expected, ButtonName(left, right));
    }
}
