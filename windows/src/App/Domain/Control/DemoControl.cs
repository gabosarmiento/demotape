using System.Globalization;

namespace DemoTape.Domain.Control;

/// <summary>
/// External control surface for DemoTape, ported from the macOS <c>DemoControl.swift</c>. It lets an
/// orchestrator (e.g. Kiro driving a browser with Playwright, or a computer-use agent) run a demo
/// hands-off: <b>start recording → drive the app → stop → collect the finished video</b> — without
/// embedding any of that logic (or any third-party dependency) inside DemoTape itself.
///
/// <para>Control comes in over a <c>demotape://</c> URL (registered + dispatched by the app layer);
/// progress goes back out via a small pollable <c>control.json</c> status file. This class holds the
/// <b>pure, testable</b> URL parsing; the side effects (starting capture, writing status) live in the
/// app/infrastructure layer.</para>
///
/// <para>URL grammar (parity with macOS):</para>
/// <code>
///   demotape://record/start                         full screen, 3-2-1 countdown
///   demotape://record/start?countdown=0             start immediately (best for automation)
///   demotape://record/start?mode=area&amp;x=&amp;y=&amp;w=&amp;h= crop to a pixel rect on the main display
///   demotape://record/start?nx=&amp;ny=&amp;nw=&amp;nh=          crop to a normalized rect (0…1, top-left)
///   demotape://record/start?mic=1&amp;webcam=0          override input toggles for this take
///   demotape://record/webcam                        talking-head to camera, no screen
///   demotape://record/stop                          stop + auto-render
/// </code>
/// </summary>
public static class DemoControl
{
    /// <summary>Where to crop the capture.</summary>
    public enum RegionKind { FullScreen, Normalized, Pixels }

    /// <summary>A capture region: full screen, or a rectangle in normalized (0…1) or pixel units.</summary>
    public readonly record struct Region(RegionKind Kind, double X, double Y, double W, double H)
    {
        public static Region FullScreen => new(RegionKind.FullScreen, 0, 0, 0, 0);
        public static Region Normalized(double x, double y, double w, double h) => new(RegionKind.Normalized, x, y, w, h);
        public static Region Pixels(double x, double y, double w, double h) => new(RegionKind.Pixels, x, y, w, h);
    }

    /// <summary>Options for a <c>record/start</c> command. Null mic/webcam = leave the current setting.</summary>
    public sealed record StartOptions
    {
        public Region Region { get; init; } = Region.FullScreen;
        public int Countdown { get; init; } = 3;   // seconds; 0 = begin immediately
        public bool? Microphone { get; init; }
        public bool? Webcam { get; init; }
        /// <summary>Record the camera only (talking-head), not the screen. <c>demotape://record/webcam</c>.</summary>
        public bool WebcamOnly { get; init; }
    }

    /// <summary>The kind of a parsed control command.</summary>
    public enum CommandKind { Start, Stop, Cursor, Type, TypingActivity, CursorPath, OpenUi, Element, DumpUi }

    /// <summary>Windows reachable through <c>demotape://ui/open?window=…</c>.</summary>
    public enum UiWindow { About, Publish, Composer, Settings, Welcome, Voiceover, Captions, Menu }

    /// <summary>A single point (screen points, top-left origin).</summary>
    public readonly record struct Point(double X, double Y);

    /// <summary>A semantic UI target resolved from the live UI (label/role/app/index).</summary>
    public sealed record ElementQuery(string Label, string? Role = null, string? App = null, int Index = 0);

    /// <summary>
    /// A parsed <c>demotape://</c> command. A discriminated union in Swift; here a single record whose
    /// <see cref="Kind"/> selects which fields are meaningful. Use the static factories to build.
    /// </summary>
    public sealed record Command
    {
        public CommandKind Kind { get; private init; }
        public StartOptions? Start { get; private init; }
        public double CursorX { get; private init; }
        public double CursorY { get; private init; }
        public bool Click { get; private init; }
        public int GlideMs { get; private init; }
        public string? Text { get; private init; }
        public double Cps { get; private init; }
        public string? ExpectedApp { get; private init; }
        public int Chars { get; private init; }
        public Point? Caret { get; private init; }
        public IReadOnlyList<Point> PathPoints { get; private init; } = Array.Empty<Point>();
        public int PathMs { get; private init; }
        public UiWindow Window { get; private init; }
        public int HoldMs { get; private init; }
        public ElementQuery? Query { get; private init; }
        public string? App { get; private init; }

        internal static Command MakeStart(StartOptions o) => new() { Kind = CommandKind.Start, Start = o };
        internal static Command MakeStop() => new() { Kind = CommandKind.Stop };
        internal static Command MakeCursor(double x, double y, bool click, int glideMs) =>
            new() { Kind = CommandKind.Cursor, CursorX = x, CursorY = y, Click = click, GlideMs = glideMs };
        internal static Command MakeType(string text, double cps, string? app) =>
            new() { Kind = CommandKind.Type, Text = text, Cps = cps, ExpectedApp = app };
        internal static Command MakeTypingActivity(int chars, double cps, Point? caret) =>
            new() { Kind = CommandKind.TypingActivity, Chars = chars, Cps = cps, Caret = caret };
        internal static Command MakeCursorPath(IReadOnlyList<Point> points, int ms) =>
            new() { Kind = CommandKind.CursorPath, PathPoints = points, PathMs = ms };
        internal static Command MakeOpenUi(UiWindow window, int holdMs) =>
            new() { Kind = CommandKind.OpenUi, Window = window, HoldMs = holdMs };
        internal static Command MakeElement(ElementQuery q, bool click) =>
            new() { Kind = CommandKind.Element, Query = q, Click = click };
        internal static Command MakeDumpUi(string? app) => new() { Kind = CommandKind.DumpUi, App = app };
    }

    /// <summary>
    /// Parses a <c>demotape://</c> control URL into a <see cref="Command"/>. Returns null for anything
    /// unrecognized or for a foreign scheme.
    /// </summary>
    public static Command? Parse(Uri? url)
    {
        if (url is null) return null;
        if (!string.Equals(url.Scheme, "demotape", StringComparison.OrdinalIgnoreCase)) return null;

        // Action can be the host (demotape://stop) or a path segment (demotape://record/stop).
        var tokens = new List<string>();
        if (!string.IsNullOrEmpty(url.Host)) tokens.Add(url.Host.ToLowerInvariant());
        foreach (var seg in url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries))
            tokens.Add(seg.ToLowerInvariant());

        // Query lookup (case-insensitive keys). Parsed by hand to stay dependency-free. Percent
        // escapes are decoded, then `+` decodes as a space — shells and scripts routinely use `+`
        // for spaces, which would otherwise fail to match a label like "Check for Updates".
        var q = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var query = url.Query.TrimStart('?');
        foreach (var pair in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            var rawKey = eq >= 0 ? pair[..eq] : pair;
            var rawVal = eq >= 0 ? pair[(eq + 1)..] : string.Empty;
            var key = Uri.UnescapeDataString(rawKey).Replace('+', ' ');
            var val = Uri.UnescapeDataString(rawVal).Replace('+', ' ');
            q[key] = val;
        }

        double? Dbl(string k) =>
            q.TryGetValue(k, out var v) && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)
                ? d : (double?)null;

        bool Has(string t) => tokens.Contains(t);

        if (Has("typing"))
        {
            // demotape://typing?chars=42&cps=14[&x=&y=]  — activity only, nothing is posted.
            var chars = Dbl("chars");
            if (chars is null || chars <= 0) return null;
            Point? caret = null;
            var cx = Dbl("x"); var cy = Dbl("y");
            if (cx is not null && cy is not null) caret = new Point(cx.Value, cy.Value);
            return Command.MakeTypingActivity((int)chars.Value, Math.Max(0, Dbl("cps") ?? 0), caret);
        }
        if (Has("type"))
        {
            // demotape://type?text=hello%20world&cps=14&app=Chromium
            if (!q.TryGetValue("text", out var text) || string.IsNullOrEmpty(text)) return null;
            q.TryGetValue("app", out var app);
            return Command.MakeType(text, Math.Max(0, Dbl("cps") ?? 0), string.IsNullOrEmpty(app) ? null : app);
        }
        if (Has("path"))
        {
            // demotape://cursor/path?pts=120,80;200,140;260,90&ms=1400
            if (!q.TryGetValue("pts", out var raw) || string.IsNullOrEmpty(raw)) return null;
            var points = new List<Point>();
            foreach (var pair in raw.Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                var parts = pair.Split(',');
                if (parts.Length != 2) continue;
                if (double.TryParse(parts[0].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var px) &&
                    double.TryParse(parts[1].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var py))
                    points.Add(new Point(px, py));
            }
            if (points.Count < 2) return null;
            int ms = (int)(Dbl("ms") ?? 0);
            return Command.MakeCursorPath(points, Math.Max(120, ms == 0 ? 900 : ms));
        }
        if (Has("cursor"))
        {
            var x = Dbl("x"); var y = Dbl("y");
            if (x is null || y is null) return null;
            // demotape://cursor/glide?x=&y=&ms=420  (ms also accepted as `glide`)
            int glide = (int)(Dbl("ms") ?? Dbl("glide") ?? 0);
            if (Has("glide") && glide <= 0) glide = 420;   // sensible default travel
            return Command.MakeCursor(x.Value, y.Value, Has("click"), Math.Max(0, glide));
        }
        if (Has("ui"))
        {
            // demotape://ui/dump?app=Safari
            if (Has("dump")) { q.TryGetValue("app", out var dumpApp); return Command.MakeDumpUi(string.IsNullOrEmpty(dumpApp) ? null : dumpApp); }
            // Semantic targeting: demotape://ui/click?label=Export&role=AXButton&app=Safari
            if (Has("click") || Has("find"))
            {
                if (!q.TryGetValue("label", out var label) || string.IsNullOrEmpty(label)) return null;
                q.TryGetValue("role", out var role);
                q.TryGetValue("app", out var app);
                int index = q.TryGetValue("index", out var idx) && int.TryParse(idx, out var i) ? i : 0;
                var elementQuery = new ElementQuery(label,
                    string.IsNullOrEmpty(role) ? null : role,
                    string.IsNullOrEmpty(app) ? null : app,
                    index);
                return Command.MakeElement(elementQuery, Has("click"));
            }
            // demotape://ui/open?window=about  — or the shorthand demotape://ui/about
            string? named = q.TryGetValue("window", out var w) && !string.IsNullOrEmpty(w)
                ? w.ToLowerInvariant()
                : (tokens.Count > 0 ? tokens[^1] : null);
            if (named is null || !TryParseWindow(named, out var win)) return null;
            int hold = (int)(Dbl("hold") ?? Dbl("holdms") ?? 0);
            return Command.MakeOpenUi(win, Math.Max(0, hold));
        }
        if (Has("stop")) return Command.MakeStop();

        // demotape://record/webcam[?countdown=&mic=]  — talking-head to camera, no screen.
        bool webcamOnly = Has("webcam");
        if (!Has("start") && !webcamOnly) return null;

        bool? Flag(params string[] keys)
        {
            foreach (var k in keys)
            {
                if (q.TryGetValue(k, out var v))
                {
                    var lv = v.ToLowerInvariant();
                    if (lv is "1" or "true" or "yes" or "on") return true;
                    if (lv is "0" or "false" or "no" or "off") return false;
                }
            }
            return null;
        }

        Region region;
        var nx = Dbl("nx"); var ny = Dbl("ny"); var nw = Dbl("nw"); var nh = Dbl("nh");
        if (nx is not null && ny is not null && nw is not null && nh is not null)
            region = Region.Normalized(nx.Value, ny.Value, nw.Value, nh.Value);
        else
        {
            var px = Dbl("x"); var py = Dbl("y"); var pw = Dbl("w"); var ph = Dbl("h");
            if (px is not null && py is not null && pw is not null && ph is not null)
                region = Region.Pixels(px.Value, py.Value, pw.Value, ph.Value);
            else
                region = Region.FullScreen;   // also the case for mode=fullscreen
        }

        int countdown = 3;
        if (q.TryGetValue("countdown", out var cv) && int.TryParse(cv, out var cn)) countdown = Math.Max(0, cn);

        var opts = new StartOptions
        {
            Region = region,
            Countdown = countdown,
            Microphone = Flag("mic", "microphone"),
            Webcam = webcamOnly ? null : Flag("webcam", "cam", "camera"),
            WebcamOnly = webcamOnly,
        };
        return Command.MakeStart(opts);
    }

    private static bool TryParseWindow(string name, out UiWindow window)
    {
        switch (name.ToLowerInvariant())
        {
            case "about": window = UiWindow.About; return true;
            case "publish": window = UiWindow.Publish; return true;
            case "composer": window = UiWindow.Composer; return true;
            case "settings": window = UiWindow.Settings; return true;
            case "welcome": window = UiWindow.Welcome; return true;
            case "voiceover": window = UiWindow.Voiceover; return true;
            case "captions": window = UiWindow.Captions; return true;
            case "menu": window = UiWindow.Menu; return true;
            default: window = default; return false;
        }
    }
}
