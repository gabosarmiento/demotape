namespace DemoTape.Domain.Rendering;

/// <summary>A point in output pixel space (top-left origin).</summary>
public readonly record struct OutputPoint(double X, double Y);

/// <summary>The zoomed viewport: the source-space rectangle that fills the output.</summary>
public readonly record struct Viewport(double OffsetX, double OffsetY, double Width, double Height);

/// <summary>
/// Pure geometry for the auto-zoom render, extracted from the macOS <c>VideoRenderer</c> so it
/// can be unit-tested independently of any GPU pipeline. All coordinates are top-left origin
/// (Windows/Win2D convention); the macOS original used a bottom-left origin but the math is
/// equivalent.
///
/// The composition is laid out as: a <see cref="Padding"/> border around a content region of
/// <c>OutputWidth - 2*Padding</c> × <c>OutputHeight - 2*Padding</c>. The camera then zooms the
/// whole composition toward a focus point (content + frame + background move together).
/// </summary>
public sealed class CameraViewport
{
    public double OutputWidth { get; }
    public double OutputHeight { get; }
    public double Padding { get; }
    public double ContentWidth => OutputWidth - Padding * 2;
    public double ContentHeight => OutputHeight - Padding * 2;

    public CameraViewport(double outputWidth, double outputHeight, double padding = 0)
    {
        if (outputWidth <= 0 || outputHeight <= 0) throw new ArgumentOutOfRangeException(nameof(outputWidth));
        if (padding < 0 || padding * 2 >= outputWidth || padding * 2 >= outputHeight)
            throw new ArgumentOutOfRangeException(nameof(padding));
        OutputWidth = outputWidth;
        OutputHeight = outputHeight;
        Padding = padding;
    }

    /// <summary>
    /// Computes the source-space viewport rectangle for a zoom <paramref name="scale"/> centered
    /// on the normalized focus point (<paramref name="centerX"/>, <paramref name="centerY"/>),
    /// clamped so the viewport never leaves the composition.
    /// </summary>
    public Viewport ComputeViewport(double scale, double centerX, double centerY)
    {
        if (scale < 1) scale = 1;
        double fx = Padding + centerX * ContentWidth;   // focus in composed coords
        double fy = Padding + centerY * ContentHeight;
        double vw = OutputWidth / scale;
        double vh = OutputHeight / scale;
        double ox = Math.Clamp(fx - vw / 2, 0, OutputWidth - vw);
        double oy = Math.Clamp(fy - vh / 2, 0, OutputHeight - vh);
        return new Viewport(ox, oy, vw, vh);
    }

    /// <summary>
    /// Maps a content-normalized point (0..1, top-left) to output pixel coordinates after the
    /// zoom described by <paramref name="scale"/> and <paramref name="viewport"/>. Returns null
    /// if the point falls outside the visible output (so overlays off-screen are skipped).
    /// </summary>
    public OutputPoint? MapToOutput(double u, double v, double scale, Viewport viewport)
    {
        double cx = Padding + u * ContentWidth;
        double cy = Padding + v * ContentHeight;
        double px = (cx - viewport.OffsetX) * scale;
        double py = (cy - viewport.OffsetY) * scale;
        if (px < 0 || px > OutputWidth || py < 0 || py > OutputHeight) return null;
        return new OutputPoint(px, py);
    }

    /// <summary>Rounds a dimension down to the nearest even number (H.264/yuv420p requirement).</summary>
    public static int Even(double v) => (int)(Math.Floor(v / 2) * 2);
}
