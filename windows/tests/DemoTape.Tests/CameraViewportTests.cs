using DemoTape.Domain.Rendering;
using Xunit;

namespace DemoTape.Tests;

public class CameraViewportTests
{
    [Fact]
    public void NoZoom_ViewportCoversWholeOutput()
    {
        var vp = new CameraViewport(1920, 1080);
        var v = vp.ComputeViewport(1.0, 0.5, 0.5);
        Assert.Equal(0, v.OffsetX, 6);
        Assert.Equal(0, v.OffsetY, 6);
        Assert.Equal(1920, v.Width, 6);
        Assert.Equal(1080, v.Height, 6);
    }

    [Fact]
    public void Zoom_HalvesViewport_AndCentersOnFocus()
    {
        var vp = new CameraViewport(1920, 1080);
        var v = vp.ComputeViewport(2.0, 0.5, 0.5);
        Assert.Equal(960, v.Width, 6);
        Assert.Equal(540, v.Height, 6);
        // Centered focus → viewport centered in the output.
        Assert.Equal((1920 - 960) / 2.0, v.OffsetX, 6);
        Assert.Equal((1080 - 540) / 2.0, v.OffsetY, 6);
    }

    [Fact]
    public void Viewport_ClampsToBounds_AtEdgeFocus()
    {
        var vp = new CameraViewport(1000, 1000);
        var v = vp.ComputeViewport(2.0, 0.0, 0.0); // focus top-left corner
        Assert.Equal(0, v.OffsetX, 6);
        Assert.Equal(0, v.OffsetY, 6);

        var v2 = vp.ComputeViewport(2.0, 1.0, 1.0); // focus bottom-right corner
        Assert.Equal(500, v2.OffsetX, 6);            // outW - vw = 1000 - 500
        Assert.Equal(500, v2.OffsetY, 6);
    }

    [Fact]
    public void MapToOutput_CenterFocus_MapsCenterToCenter()
    {
        var vp = new CameraViewport(1000, 1000);
        var view = vp.ComputeViewport(2.0, 0.5, 0.5);
        var p = vp.MapToOutput(0.5, 0.5, 2.0, view);
        Assert.NotNull(p);
        Assert.Equal(500, p!.Value.X, 6);
        Assert.Equal(500, p.Value.Y, 6);
    }

    [Fact]
    public void MapToOutput_ReturnsNull_WhenOffScreen()
    {
        var vp = new CameraViewport(1000, 1000);
        var view = vp.ComputeViewport(2.0, 0.5, 0.5); // shows the central quarter
        // A point in the far corner is outside the zoomed viewport.
        Assert.Null(vp.MapToOutput(0.0, 0.0, 2.0, view));
    }

    [Fact]
    public void Padding_ShrinksContentRegion()
    {
        var vp = new CameraViewport(1096, 776, padding: 48);
        Assert.Equal(1000, vp.ContentWidth, 6);
        Assert.Equal(680, vp.ContentHeight, 6);
    }

    [Fact]
    public void Even_RoundsDownToEven()
    {
        Assert.Equal(1080, CameraViewport.Even(1080));
        Assert.Equal(1080, CameraViewport.Even(1081));
        Assert.Equal(966, CameraViewport.Even(967));
    }

    [Fact]
    public void Constructor_RejectsInvalidPadding()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new CameraViewport(100, 100, 60));
    }
}
