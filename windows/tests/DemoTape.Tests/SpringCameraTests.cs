using DemoTape.Domain.Rendering;
using Xunit;

namespace DemoTape.Tests;

public class SpringCameraTests
{
    [Fact]
    public void FirstStep_SnapsToTarget()
    {
        var cam = new SpringCamera();
        cam.Step(new FocusTarget(2.0, 0.3, 0.7), dt: 1.0 / 30);
        Assert.Equal(2.0, cam.Scale, 6);
        Assert.Equal(0.3, cam.CenterX, 6);
        Assert.Equal(0.7, cam.CenterY, 6);
    }

    [Fact]
    public void ConvergesTowardTarget_OverTime()
    {
        var cam = new SpringCamera();
        cam.Step(new FocusTarget(1.0, 0.5, 0.5), 1.0 / 30);   // initialize at 1.0
        var target = new FocusTarget(2.0, 0.2, 0.8);
        for (int i = 0; i < 240; i++)
            cam.Step(target, 1.0 / 60);

        Assert.Equal(2.0, cam.Scale, 2);
        Assert.Equal(0.2, cam.CenterX, 2);
        Assert.Equal(0.8, cam.CenterY, 2);
    }

    [Fact]
    public void CriticallyDamped_DoesNotWildlyOvershoot()
    {
        var cam = new SpringCamera();
        cam.Step(new FocusTarget(1.0, 0.5, 0.5), 1.0 / 60);
        var target = new FocusTarget(2.0, 0.5, 0.5);
        double maxScale = 1.0;
        for (int i = 0; i < 300; i++)
        {
            cam.Step(target, 1.0 / 60);
            maxScale = Math.Max(maxScale, cam.Scale);
        }
        // With k=130, c=23 the response is near-critically damped: minimal overshoot.
        Assert.True(maxScale < 2.15, $"overshoot too large: {maxScale}");
    }
}
