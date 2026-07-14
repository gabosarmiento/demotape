namespace DemoTape.App.Infrastructure;

/// <summary>
/// Click-through, per-pixel-transparent overlay that draws a brand-blue border around the whole
/// screen while a full-screen recording is in progress — a clear "you are recording" cue. Excluded
/// from screen capture, so the border is only visible on-screen and never appears in the video.
/// </summary>
public sealed class FullScreenBorderOverlay : LayeredOverlay
{
    public FullScreenBorderOverlay() : base(clickThrough: true)
    {
        ExcludeFromCapture();
        Present(OverlayPainter.BorderOnly(Width, Height, OverlayPainter.BrandBright, thickness: 6));
    }
}
