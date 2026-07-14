using DemoTape.Domain.Models;

namespace DemoTape.Domain.Rendering;

/// <summary>A focus target for the auto-zoom camera at a point in time.</summary>
public readonly record struct FocusTarget(double Scale, double CenterX, double CenterY);

/// <summary>A normalized point (top-left origin, 0..1).</summary>
public readonly record struct NormalizedPoint(double X, double Y);

/// <summary>
/// Computes the auto-zoom "camera" over time from the captured event timeline.
/// Direct port of the macOS <c>FocusTimeline</c>.
///
/// Zoom is driven by <em>activity</em>: clicks and typing both keep the camera zoomed.
/// The focus center anchors to the most recent click (so while you type, the view stays
/// locked on the field you clicked into — "text input tracking" — instead of zooming out),
/// and follows the cursor otherwise. Temporal smoothing (a spring) is applied by the renderer
/// across frames (see <see cref="SpringCamera"/>).
/// </summary>
public sealed class FocusTimeline
{
    private readonly List<ClickSample> _clicks;
    private readonly List<CursorSample> _cursor;
    private readonly List<KeySample> _keys;

    public double MaxZoom { get; }

    // Click zoom window
    private const double ClickRampIn = 0.4;
    private const double ClickHold = 1.6;
    private const double ClickRampOut = 0.8;
    // Typing keeps the zoom alive; each key extends this window.
    private const double TypeRampIn = 0.12;
    private const double TypeHold = 1.5;
    private const double TypeRampOut = 0.7;

    public FocusTimeline(RecordingMetadata metadata, double maxZoom = 2.0)
    {
        ArgumentNullException.ThrowIfNull(metadata);
        _clicks = metadata.Clicks.OrderBy(c => c.T).ToList();
        _cursor = metadata.Cursor.OrderBy(c => c.T).ToList();
        _keys = metadata.Keys.OrderBy(k => k.T).ToList();
        MaxZoom = maxZoom;
    }

    /// <summary>Activity level 0..1 at time <paramref name="t"/>.</summary>
    public double Activity(double t)
    {
        double a = 0.0;
        foreach (var c in _clicks)
        {
            a = Math.Max(a, Bump(t - c.T, ClickRampIn, ClickHold, ClickRampOut));
            if (a >= 1) return 1;
        }
        foreach (var k in _keys)
        {
            a = Math.Max(a, Bump(t - k.T, TypeRampIn, TypeHold, TypeRampOut));
            if (a >= 1) return 1;
        }
        return a;
    }

    /// <summary>The zoom scale and clamped focus center at time <paramref name="t"/>.</summary>
    public FocusTarget Target(double t)
    {
        double a = Activity(t);
        double scale = 1.0 + a * (MaxZoom - 1.0);

        var anchor = FocusAnchor(t);
        double cx = 0.5 + a * (anchor.X - 0.5);
        double cy = 0.5 + a * (anchor.Y - 0.5);

        double half = 0.5 / scale;
        cx = Math.Clamp(cx, half, 1 - half);
        cy = Math.Clamp(cy, half, 1 - half);
        return new FocusTarget(scale, cx, cy);
    }

    /// <summary>
    /// Where the camera should look: the field/point being worked on. While typing, this is
    /// the last click (the focused input); otherwise it tracks the cursor.
    /// </summary>
    private NormalizedPoint FocusAnchor(double t)
    {
        ClickSample? lastClick = LastAtOrBefore(_clicks, t, c => c.T);
        KeySample? lastKey = LastAtOrBefore(_keys, t, k => k.T);

        bool typing = lastKey is not null
            && (lastClick is null || lastKey.T >= lastClick.T)
            && (t - lastKey.T) < TypeHold;

        if (typing && lastClick is not null)
            return new NormalizedPoint(lastClick.X, lastClick.Y); // hold on the text field
        if (lastClick is not null && (t - lastClick.T) < ClickHold)
            return new NormalizedPoint(lastClick.X, lastClick.Y); // hold on the last click

        return CursorPoint(t); // otherwise follow the cursor
    }

    /// <summary>
    /// Active keyboard-shortcut badge (e.g. "Ctrl+Shift+D") at time <paramref name="t"/>, or null.
    /// Only shortcuts (with Ctrl/Alt/Win) are shown — plain typing produces no badge.
    /// </summary>
    public string? ShortcutBadge(double t, double window = 1.1)
    {
        for (int i = _keys.Count - 1; i >= 0; i--)
        {
            var k = _keys[i];
            if (k.T > t) continue;
            if (t - k.T > window) break;
            if (IsShortcut(k)) return BadgeLabel(k);
        }
        return null;
    }

    private static bool IsShortcut(KeySample k) =>
        k.Modifiers.Contains("ctrl") || k.Modifiers.Contains("cmd") ||
        k.Modifiers.Contains("win") || k.Modifiers.Contains("alt") || k.Modifiers.Contains("opt");

    /// <summary>Builds a Windows-style shortcut label, e.g. "Ctrl+Shift+C".</summary>
    public static string BadgeLabel(KeySample k)
    {
        var parts = new List<string>();
        if (k.Modifiers.Contains("ctrl") || k.Modifiers.Contains("cmd")) parts.Add("Ctrl");
        if (k.Modifiers.Contains("alt") || k.Modifiers.Contains("opt")) parts.Add("Alt");
        if (k.Modifiers.Contains("shift")) parts.Add("Shift");
        if (k.Modifiers.Contains("win")) parts.Add("Win");
        parts.Add(KeyName(k.KeyCode, k.Chars));
        return string.Join("+", parts);
    }

    /// <summary>Maps a Windows virtual-key code (or the typed character) to a display name.</summary>
    private static string KeyName(int code, string chars)
    {
        switch (code)
        {
            case 0x0D: return "Enter";      // VK_RETURN
            case 0x09: return "Tab";        // VK_TAB
            case 0x20: return "Space";      // VK_SPACE
            case 0x08: return "Backspace";  // VK_BACK
            case 0x1B: return "Esc";        // VK_ESCAPE
            case 0x2E: return "Del";        // VK_DELETE
            case 0x25: return "←";          // VK_LEFT
            case 0x27: return "→";          // VK_RIGHT
            case 0x28: return "↓";          // VK_DOWN
            case 0x26: return "↑";          // VK_UP
            default:
                var c = chars.Trim();
                return string.IsNullOrEmpty(c) ? "?" : c.ToUpperInvariant();
        }
    }

    /// <summary>Public interpolated cursor position at <paramref name="t"/> (normalized, top-left).</summary>
    public NormalizedPoint CursorPoint(double t)
    {
        if (_cursor.Count == 0) return new NormalizedPoint(0.5, 0.5);
        if (t <= _cursor[0].T) return new NormalizedPoint(_cursor[0].X, _cursor[0].Y);
        var last = _cursor[^1];
        if (t >= last.T) return new NormalizedPoint(last.X, last.Y);

        int lo = 0, hi = _cursor.Count - 1;
        while (lo < hi)
        {
            int mid = (lo + hi) / 2;
            if (_cursor[mid].T < t) lo = mid + 1; else hi = mid;
        }
        var b = _cursor[lo];
        var a = _cursor[Math.Max(0, lo - 1)];
        double span = b.T - a.T;
        double f = span > 0 ? (t - a.T) / span : 0;
        return new NormalizedPoint(a.X + (b.X - a.X) * f, a.Y + (b.Y - a.Y) * f);
    }

    // MARK: - Helpers

    /// <summary>Trapezoidal activity envelope: ramp in, hold at 1, ramp out.</summary>
    private static double Bump(double dt, double rampIn, double hold, double rampOut)
    {
        if (dt < 0)
            return dt > -rampIn ? Smoothstep((dt + rampIn) / rampIn) : 0;
        if (dt <= hold)
            return 1;
        if (dt <= hold + rampOut)
            return 1 - Smoothstep((dt - hold) / rampOut);
        return 0;
    }

    private static double Smoothstep(double x)
    {
        double c = Math.Clamp(x, 0, 1);
        return c * c * (3 - 2 * c);
    }

    private static T? LastAtOrBefore<T>(List<T> items, double t, Func<T, double> time) where T : class
    {
        T? found = null;
        foreach (var item in items)
        {
            if (time(item) <= t) found = item; else break;
        }
        return found;
    }
}
