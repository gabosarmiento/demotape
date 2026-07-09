namespace DemoTape.App.Infrastructure;

/// <summary>
/// Builds premultiplied-BGRA pixel buffers for the layered overlays: a translucent dim over the
/// whole screen with an optional clear rectangle punched out, framed by a border and corner grips.
/// </summary>
internal static class OverlayPainter
{
    public readonly record struct Rgba(byte R, byte G, byte B, byte A);

    /// <summary>DemoTape brand cyan-blue (sampled from the logo) and a brighter variant for cues.</summary>
    public static readonly Rgba Brand = new(0x22, 0xB0, 0xE6, 0xFF);
    public static readonly Rgba BrandBright = new(0x3A, 0xCE, 0xF2, 0xFF);
    public static readonly Rgba White = new(255, 255, 255, 255);

    /// <summary>
    /// Fills a full-screen dim (<paramref name="dimAlpha"/> over black) with the region cleared out
    /// and a border drawn just outside it. Corner grips are drawn for interactive selection.
    /// </summary>
    public static byte[] Build(int w, int h, RectI? hole, byte dimAlpha, Rgba border, int borderThickness, bool grips)
    {
        var buf = new byte[w * h * 4];

        // Dim everything (premultiplied black at dimAlpha => B=G=R=0, A=dimAlpha).
        for (int i = 0; i < buf.Length; i += 4)
        {
            buf[i + 3] = dimAlpha; // A (BGRA: index+3 is alpha)
        }

        if (hole is null) return buf;
        var r = hole.Value;

        // Clear the interior (fully transparent) so the desktop shows through cleanly.
        int x0 = Math.Clamp(r.X, 0, w), y0 = Math.Clamp(r.Y, 0, h);
        int x1 = Math.Clamp(r.X + r.W, 0, w), y1 = Math.Clamp(r.Y + r.H, 0, h);
        for (int y = y0; y < y1; y++)
        {
            int row = y * w * 4;
            for (int x = x0; x < x1; x++)
            {
                int p = row + x * 4;
                buf[p] = buf[p + 1] = buf[p + 2] = buf[p + 3] = 0;
            }
        }

        // Border frame drawn OUTSIDE the hole (so it never lands inside the recorded region).
        for (int t = 1; t <= borderThickness; t++)
            DrawRectOutline(buf, w, h, r.X - t, r.Y - t, r.W + t * 2, r.H + t * 2, border);

        if (grips) DrawGrips(buf, w, h, r);
        return buf;
    }

    /// <summary>A transparent buffer with only a solid border frame around the whole screen edge.</summary>
    public static byte[] BorderOnly(int w, int h, Rgba color, int thickness)
    {
        var buf = new byte[w * h * 4];
        for (int t = 0; t < thickness; t++)
            DrawRectOutline(buf, w, h, t, t, w - t * 2, h - t * 2, color);
        return buf;
    }

    private static void DrawRectOutline(byte[] buf, int w, int h, int x, int y, int rw, int rh, Rgba c)
    {
        for (int px = x; px < x + rw; px++)
        {
            SetPx(buf, w, h, px, y, c);
            SetPx(buf, w, h, px, y + rh - 1, c);
        }
        for (int py = y; py < y + rh; py++)
        {
            SetPx(buf, w, h, x, py, c);
            SetPx(buf, w, h, x + rw - 1, py, c);
        }
    }

    private static void DrawGrips(byte[] buf, int w, int h, RectI r)
    {
        const int g = 6;
        var white = new Rgba(255, 255, 255, 255);
        (int cx, int cy)[] corners =
        {
            (r.X, r.Y), (r.X + r.W, r.Y), (r.X, r.Y + r.H), (r.X + r.W, r.Y + r.H),
            (r.X + r.W / 2, r.Y), (r.X + r.W / 2, r.Y + r.H),
            (r.X, r.Y + r.H / 2), (r.X + r.W, r.Y + r.H / 2),
        };
        foreach (var (cx, cy) in corners)
            for (int dy = -g; dy <= g; dy++)
                for (int dx = -g; dx <= g; dx++)
                    SetPx(buf, w, h, cx + dx, cy + dy, white);
    }

    private static void SetPx(byte[] buf, int w, int h, int x, int y, Rgba c)
    {
        if (x < 0 || y < 0 || x >= w || y >= h) return;
        int p = (y * w + x) * 4;
        // Premultiplied BGRA.
        buf[p] = (byte)(c.B * c.A / 255);
        buf[p + 1] = (byte)(c.G * c.A / 255);
        buf[p + 2] = (byte)(c.R * c.A / 255);
        buf[p + 3] = c.A;
    }
}

/// <summary>Integer rectangle in screen pixels (top-left origin).</summary>
internal readonly record struct RectI(int X, int Y, int W, int H);
