using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Posts real OS mouse/keyboard input for the <c>demotape://</c> control surface — the Windows
/// analogue of the macOS <c>performControlCursor</c> / <c>performControlTyping</c> using
/// <c>SendInput</c> + <c>SetCursorPos</c>. Real input matters because DemoTape's auto-zoom is driven
/// by the clicks and keys its low-level hooks observe: a browser tool's synthetic events are invisible
/// to that hook, so a scripted click would move nothing and the camera would never zoom. Injected
/// input, by contrast, flows through <c>WH_MOUSE_LL</c>/<c>WH_KEYBOARD_LL</c> and lands in the timeline.
///
/// <para>Coordinates are screen pixels, top-left origin — the same space the driver sends and the
/// process is DPI-aware (per the app manifest), so <c>SetCursorPos</c> maps 1:1 to physical pixels.</para>
///
/// <para>Motion is eased and typing rhythm is uneven on purpose: a teleporting pointer or a metronome
/// cadence reads as a robot on video. All methods run synchronously on the caller's (background) thread
/// — the controller serialises them so a glide can't stall URL handling.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class GestureInjector
{
    /// <summary>Move (optionally gliding) to a point, then optionally click it.</summary>
    public void CursorTo(double x, double y, bool click, int glideMs)
    {
        if (glideMs > 0) Glide((int)Math.Round(x), (int)Math.Round(y), glideMs);
        else SetCursorPos((int)Math.Round(x), (int)Math.Round(y));

        if (!click) return;
        Thread.Sleep(120);   // land, aim, then press — a human beat
        LeftButton(down: true);
        Thread.Sleep(60);    // real presses have dwell; an instant down/up gets swallowed by some controls
        LeftButton(down: false);
    }

    /// <summary>Sweep the pointer through a whole path as one continuous, eased motion.</summary>
    public void CursorPath(IReadOnlyList<DemoTape.Domain.Control.DemoControl.Point> points, int ms)
    {
        if (points.Count == 0) return;
        if (points.Count == 1) { SetCursorPos((int)points[0].X, (int)points[0].Y); return; }

        // Total path length, so time is distributed by distance (constant-ish speed along the shape).
        double total = 0;
        for (int i = 1; i < points.Count; i++) total += Dist(points[i - 1], points[i]);
        if (total < 1) { SetCursorPos((int)points[^1].X, (int)points[^1].Y); return; }

        int steps = Math.Clamp(ms / 13, 24, 240);
        for (int s = 1; s <= steps; s++)
        {
            double u = Ease((double)s / steps);      // eased 0..1 along the whole gesture
            var p = PointAtFraction(points, u, total);
            SetCursorPos((int)Math.Round(p.X), (int)Math.Round(p.Y));
            Thread.Sleep(Math.Max(1, ms / steps));
        }
    }

    /// <summary>Type real Unicode keystrokes with a human-uneven cadence into the focused window.</summary>
    public void Type(string text, double cps)
    {
        double perChar = 1.0 / Math.Max(4.0, cps > 0 ? cps : 14.0);   // default ≈14 chars/s
        var rng = new Random();
        foreach (var ch in text)
        {
            SendUnicode(ch);
            // Sentence punctuation gets a longer beat than letters; add jitter so it isn't a metronome.
            double beat = perChar * (ch is '.' or ',' or '!' or '?' or ';' or ':' ? 3.2 : 1.0);
            beat *= 0.7 + rng.NextDouble() * 0.6;
            Thread.Sleep((int)(beat * 1000));
        }
    }

    // ---- easing / geometry ----

    private static double Ease(double t) => t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t;   // easeInOut
    private static double Dist(DemoTape.Domain.Control.DemoControl.Point a, DemoTape.Domain.Control.DemoControl.Point b)
        => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    private static DemoTape.Domain.Control.DemoControl.Point PointAtFraction(
        IReadOnlyList<DemoTape.Domain.Control.DemoControl.Point> pts, double u, double total)
    {
        double target = u * total, acc = 0;
        for (int i = 1; i < pts.Count; i++)
        {
            double seg = Dist(pts[i - 1], pts[i]);
            if (acc + seg >= target || i == pts.Count - 1)
            {
                double local = seg <= 0 ? 0 : (target - acc) / seg;
                return new DemoTape.Domain.Control.DemoControl.Point(
                    pts[i - 1].X + (pts[i].X - pts[i - 1].X) * local,
                    pts[i - 1].Y + (pts[i].Y - pts[i - 1].Y) * local);
            }
            acc += seg;
        }
        return pts[^1];
    }

    private void Glide(int tx, int ty, int ms)
    {
        GetCursorPos(out var start);
        double dx = tx - start.X, dy = ty - start.Y;
        if (Math.Sqrt(dx * dx + dy * dy) < 1) { SetCursorPos(tx, ty); return; }
        int steps = Math.Clamp(ms / 13, 12, 120);
        for (int s = 1; s <= steps; s++)
        {
            double e = Ease((double)s / steps);
            SetCursorPos((int)Math.Round(start.X + dx * e), (int)Math.Round(start.Y + dy * e));
            Thread.Sleep(Math.Max(1, ms / steps));
        }
        SetCursorPos(tx, ty);
    }

    // ---- SendInput plumbing ----

    private static void LeftButton(bool down)
    {
        var input = new INPUT
        {
            type = INPUT_MOUSE,
            u = new InputUnion { mi = new MOUSEINPUT { dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP } }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    private static void SendUnicode(char ch)
    {
        var down = new INPUT
        {
            type = INPUT_KEYBOARD,
            u = new InputUnion { ki = new KEYBDINPUT { wScan = ch, dwFlags = KEYEVENTF_UNICODE } }
        };
        var up = down;
        up.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        SendInput(2, new[] { down, up }, Marshal.SizeOf<INPUT>());
    }

    private const int INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public int type; public InputUnion u; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT lpPoint);
}
