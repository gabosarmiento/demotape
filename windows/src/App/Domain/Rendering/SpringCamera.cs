namespace DemoTape.Domain.Rendering;

/// <summary>
/// Critically-damped spring for smooth camera motion. Direct port of the macOS
/// renderer's private <c>SpringCamera</c>. Advances scale/center toward a target each
/// frame using semi-implicit Euler integration. Extracted from the renderer so the
/// motion model is unit-testable independently of any GPU pipeline.
/// </summary>
public sealed class SpringCamera
{
    public double Scale { get; private set; } = 1;
    public double CenterX { get; private set; } = 0.5;
    public double CenterY { get; private set; } = 0.5;

    private double _vScale, _vx, _vy;
    private bool _started;

    /// <summary>Advances the camera one frame toward <paramref name="target"/>.</summary>
    /// <param name="dt">Frame delta in seconds.</param>
    /// <param name="stiffness">Spring stiffness (k). macOS default 130.</param>
    /// <param name="damping">Spring damping (c). macOS default 23 (≈ critically damped).</param>
    public void Step(FocusTarget target, double dt, double stiffness = 130, double damping = 23)
    {
        if (!_started)
        {
            Scale = target.Scale;
            CenterX = target.CenterX;
            CenterY = target.CenterY;
            _started = true;
            return;
        }

        double scale = Scale, cx = CenterX, cy = CenterY;
        Spring(ref scale, ref _vScale, target.Scale, dt, stiffness, damping);
        Spring(ref cx, ref _vx, target.CenterX, dt, stiffness, damping);
        Spring(ref cy, ref _vy, target.CenterY, dt, stiffness, damping);
        Scale = scale; CenterX = cx; CenterY = cy;
    }

    private static void Spring(ref double x, ref double v, double target, double dt, double k, double c)
    {
        double a = -k * (x - target) - c * v;
        v += a * dt;
        x += v * dt;
    }
}
