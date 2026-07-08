using System.Text.Json;
using DemoTape.Domain.Models;
using DemoTape.Domain.Rendering;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI;
using Windows.Foundation.Collections;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Media.Effects;
using Windows.Media.MediaProperties;
using Windows.UI;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// A Win2D per-frame video effect that applies DemoTape's signature styling — spring-smoothed
/// auto-zoom, a synthetic smooth cursor, click ripples, and keyboard-shortcut badges — driven by
/// the recorded event timeline. This is the Windows analogue of the macOS Core Image render loop,
/// but plugged into the Media Foundation pipeline via <see cref="IBasicVideoEffect"/> so
/// <c>MediaComposition</c> encodes the styled output.
///
/// The effect is instantiated by the media pipeline (parameterless ctor); parameters arrive via
/// <see cref="SetProperties"/> — notably the path to the events.json sidecar, which drives all
/// motion using the unit-tested <see cref="FocusTimeline"/>/<see cref="SpringCamera"/>/<see cref="CameraViewport"/>.
/// </summary>
public sealed class AutoZoomVideoEffect : IBasicVideoEffect
{
    private CanvasDevice? _device;
    private FocusTimeline? _focus;
    private SpringCamera? _camera;
    private CameraViewport? _viewport;
    private double _lastT = -1;
    private double _maxZoom = 2.0;
    private bool _drawCursor = true, _showBadges = true, _showRipples = true;
    private double _eventOffset;

    public bool IsReadOnly => false;
    public MediaMemoryTypes SupportedMemoryTypes => MediaMemoryTypes.Gpu;
    public bool TimeIndependent => false;

    public IReadOnlyList<VideoEncodingProperties> SupportedEncodingProperties => new List<VideoEncodingProperties>();

    public void SetEncodingProperties(VideoEncodingProperties encodingProperties, IDirect3DDevice device)
    {
        _device = CanvasDevice.CreateFromDirect3D11Device(device);
    }

    public void SetProperties(IPropertySet configuration)
    {
        var sidecar = configuration.TryGetValue("sidecar", out var s) ? s as string : null;
        if (configuration.TryGetValue("maxZoom", out var mz) && mz is double d) _maxZoom = d;
        if (configuration.TryGetValue("drawCursor", out var dc) && dc is bool b1) _drawCursor = b1;
        if (configuration.TryGetValue("showBadges", out var sb) && sb is bool b2) _showBadges = b2;
        if (configuration.TryGetValue("showRipples", out var sr) && sr is bool b3) _showRipples = b3;

        if (sidecar is not null && File.Exists(sidecar))
        {
            var meta = JsonSerializer.Deserialize<RecordingMetadata>(File.ReadAllText(sidecar),
                new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
            if (meta is not null)
            {
                _focus = new FocusTimeline(meta, _maxZoom);
                _camera = new SpringCamera();
                _eventOffset = meta.EventTimeOffset ?? 0;
                _clicks = meta.Clicks;
            }
        }
    }

    private List<ClickSample> _clicks = new();
    private const double RippleDuration = 0.5;

    public void ProcessFrame(ProcessVideoFrameContext context)
    {
        var inputSurface = context.InputFrame.Direct3DSurface;
        var outputSurface = context.OutputFrame.Direct3DSurface;
        if (_device is null || inputSurface is null || outputSurface is null) return;

        using var input = CanvasBitmap.CreateFromDirect3D11Surface(_device, inputSurface);
        using var output = CanvasRenderTarget.CreateFromDirect3D11Surface(_device, outputSurface);

        double outW = output.SizeInPixels.Width;
        double outH = output.SizeInPixels.Height;
        _viewport ??= new CameraViewport(outW, outH);

        double t = context.InputFrame.RelativeTime?.TotalSeconds ?? 0;
        double eventT = t + _eventOffset;
        double dt = _lastT < 0 ? 1.0 / 30 : Math.Clamp(t - _lastT, 1.0 / 240, 1.0 / 20);
        _lastT = t;

        double scale = 1, cx = 0.5, cy = 0.5;
        if (_focus is not null && _camera is not null)
        {
            var target = _focus.Target(eventT);
            _camera.Step(target, dt);
            scale = _camera.Scale; cx = _camera.CenterX; cy = _camera.CenterY;
        }
        var view = _viewport.ComputeViewport(scale, cx, cy);

        using var ds = output.CreateDrawingSession();
        ds.Clear(Colors.Black);

        // Zoom: draw the source region (viewport) stretched to fill the output.
        var srcRect = new Windows.Foundation.Rect(view.OffsetX, view.OffsetY, view.Width, view.Height);
        var dstRect = new Windows.Foundation.Rect(0, 0, outW, outH);
        ds.DrawImage(input, dstRect, srcRect);

        if (_focus is null) return;

        // Click ripples (constant screen size, positioned via the same mapping).
        if (_showRipples)
        {
            foreach (var c in _clicks)
            {
                double age = eventT - c.T;
                if (age < 0 || age > RippleDuration) continue;
                var p = _viewport.MapToOutput(c.X, c.Y, scale, view);
                if (p is null) continue;
                double prog = age / RippleDuration;
                float radius = (float)(outW * 0.05 * prog);
                if (radius < 1) continue;
                var color = Color.FromArgb((byte)(230 * (1 - prog)), 255, 255, 255);
                ds.DrawCircle((float)p.Value.X, (float)p.Value.Y, radius, color, 3f);
            }
        }

        // Synthetic cursor.
        if (_drawCursor)
        {
            var cur = _focus.CursorPoint(eventT);
            var p = _viewport.MapToOutput(cur.X, cur.Y, scale, view);
            if (p is not null) DrawCursor(ds, (float)p.Value.X, (float)p.Value.Y);
        }

        // Keyboard-shortcut badge (bottom-center).
        if (_showBadges)
        {
            var label = _focus.ShortcutBadge(eventT);
            if (label is not null) DrawBadge(ds, label, outW, outH);
        }
    }

    private static void DrawCursor(CanvasDrawingSession ds, float x, float y)
    {
        // A simple arrow: filled white with a dark outline, tip at (x, y).
        using var path = new CanvasPathBuilder(ds.Device);
        float k = 22f;
        (float dx, float dy)[] pts =
        {
            (0, 0), (0, 0.73f), (0.16f, 0.57f), (0.28f, 0.84f),
            (0.38f, 0.80f), (0.26f, 0.54f), (0.5f, 0.51f),
        };
        path.BeginFigure(x, y);
        foreach (var (dx, dy) in pts[1..]) path.AddLine(x + dx * k, y + dy * k);
        path.EndFigure(CanvasFigureLoop.Closed);
        using var geo = CanvasGeometry.CreatePath(path);
        ds.FillGeometry(geo, Colors.White);
        ds.DrawGeometry(geo, Color.FromArgb(230, 0, 0, 0), 1.4f);
    }

    private static void DrawBadge(CanvasDrawingSession ds, string label, double outW, double outH)
    {
        using var format = new CanvasTextFormat
        {
            FontSize = 34,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = CanvasHorizontalAlignment.Center,
        };
        using var layout = new CanvasTextLayout(ds, label, format, 600, 80);
        var b = layout.LayoutBounds;
        float padX = 24, padY = 12;
        float w = (float)(b.Width + padX * 2), h = (float)(b.Height + padY * 2);
        float x = (float)((outW - w) / 2), y = (float)(outH - h - 90);
        ds.FillRoundedRectangle(x, y, w, h, 14, 14, Color.FromArgb(200, 20, 20, 20));
        ds.DrawTextLayout(layout, x + padX, y + padY, Colors.White);
    }

    public void Close(MediaEffectClosedReason reason) { _device?.Dispose(); _device = null; }
    public void DiscardQueuedFrames() { _lastT = -1; _camera = _focus is null ? null : new SpringCamera(); }
}
