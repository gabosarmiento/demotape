namespace DemoTape.App.Infrastructure;

/// <summary>
/// Click-through, per-pixel-transparent overlay shown while recording a region: it dims the area
/// around the recorded region (leaving the region itself clear) and frames it in red, so the
/// boundaries stay visible the whole time. The dim/frame sit outside the region, so they never
/// appear in the cropped output.
/// </summary>
public sealed class RecordingBoundsOverlay : LayeredOverlay
{
    public RecordingBoundsOverlay(double regionX, double regionY, double regionW, double regionH)
        : base(clickThrough: true)
    {
        // Not captured (WDA_EXCLUDEFROMCAPTURE): the dim/frame are an on-screen cue only.
        ExcludeFromCapture();
        var hole = new RectI(
            (int)Math.Round(regionX * Width), (int)Math.Round(regionY * Height),
            (int)Math.Round(regionW * Width), (int)Math.Round(regionH * Height));
        Present(OverlayPainter.Build(Width, Height, hole, dimAlpha: 90,
            border: OverlayPainter.BrandBright, borderThickness: 3, grips: false));
    }
}
