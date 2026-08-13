namespace DemoTape.Domain;

/// <summary>
/// Named capture-area preset (width × height in pixels). Mirrors the macOS <c>AreaPreset</c>.
/// </summary>
public sealed record AreaPreset(string Name, int Width, int Height)
{
    /// <summary>All available presets in display order.</summary>
    public static readonly IReadOnlyList<AreaPreset> All = new[]
    {
        new AreaPreset("Full HD (1920×1080)", 1920, 1080),
        new AreaPreset("720p (1280×720)",     1280,  720),
        new AreaPreset("4:3 (1024×768)",      1024,  768),
        new AreaPreset("Square (1080×1080)",  1080, 1080),
        new AreaPreset("Portrait 9:16 (608×1080)", 608, 1080),
    };

    /// <summary>
    /// Returns a normalized rect (X, Y, W, H in [0..1]) that centers this preset at the given
    /// <paramref name="centerNX"/> / <paramref name="centerNY"/> (normalized) and clamps it so
    /// the rect stays within the display of <paramref name="screenW"/>×<paramref name="screenH"/>
    /// pixels. If the preset is larger than the screen in either dimension, the size is clamped
    /// to fit.
    /// </summary>
    public (double X, double Y, double W, double H) CenteredRect(
        double centerNX, double centerNY, int screenW, int screenH)
    {
        if (screenW <= 0 || screenH <= 0)
            return (0, 0, 1, 1);

        // Normalized preset dimensions, clamped to screen.
        double nw = Math.Min((double)Width  / screenW, 1.0);
        double nh = Math.Min((double)Height / screenH, 1.0);

        // Center, then clamp so the rect stays inside [0, 1].
        double nx = Math.Clamp(centerNX - nw / 2, 0.0, Math.Max(0.0, 1.0 - nw));
        double ny = Math.Clamp(centerNY - nh / 2, 0.0, Math.Max(0.0, 1.0 - nh));

        return (nx, ny, nw, nh);
    }
}
