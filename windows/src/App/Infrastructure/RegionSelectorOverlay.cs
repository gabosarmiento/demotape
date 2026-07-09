using System.IO;
using System.Runtime.InteropServices;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Interactive drag-to-select overlay (per-pixel transparent, like the native Windows snip), run on
/// its own STA thread with a dedicated message loop for reliable input. Drag to create a rectangle;
/// then move it (drag inside) or resize it (drag an edge/corner) with the matching cursors — always
/// clamped inside the screen. Double-click or Enter confirms; Esc or right-click cancels. Reports the
/// region normalized to the screen (0..1, top-left) or null if cancelled.
/// </summary>
public sealed class RegionSelectorOverlay
{
    private enum Op { None, Creating, Moving, Resizing }
    private enum Zone { Outside, Inside, N, S, E, W, NE, NW, SE, SW }

    private readonly Action<(double X, double Y, double W, double H)> _onRegion;
    private readonly Action _onCancel;
    private readonly int _sw, _sh;
    private readonly Thread _thread;
    private readonly WndProcDelegate _proc; // keep alive

    private IntPtr _hwnd, _memDc, _dib, _oldBmp, _bits;
    private RectI? _rect;
    private Op _op;
    private Zone _resizeZone;
    private int _dragX, _dragY;
    private RectI _orig;
    private bool _cancelled;

    private IntPtr _curArrow, _curCross, _curNS, _curWE, _curNWSE, _curNESW, _curAll;

    /// <param name="onRegion">Called (on the selector thread) each time a region is created or
    /// edited — the region is auto-accepted on mouse release, no confirm gesture needed.</param>
    /// <param name="onCancel">Called if the user cancels with Esc / right-click.</param>
    public RegionSelectorOverlay(Action<(double X, double Y, double W, double H)> onRegion, Action onCancel)
    {
        _onRegion = onRegion;
        _onCancel = onCancel;
        _sw = GetSystemMetrics(0);
        _sh = GetSystemMetrics(1);
        _proc = WndProc;
        _thread = new Thread(Run) { IsBackground = true, Name = "DemoTape.RegionSelector" };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
    }

    /// <summary>The overlay's window handle (0 until created), for z-order management.</summary>
    public IntPtr Hwnd => _hwnd;

    /// <summary>Closes the overlay WITHOUT cancelling (used when recording starts / locks the region).</summary>
    public void Dispose()
    {
        if (_hwnd != IntPtr.Zero) PostMessage(_hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
    }

    private static int _instanceSeq;

    private void Run()
    {
        // Unique class per instance: the WndProc is bound to THIS instance's delegate, so reusing a
        // shared class name would route a re-opened selector to a stale instance's proc.
        string cls = "DemoTapeRegionSelector_" + System.Threading.Interlocked.Increment(ref _instanceSeq);
        _curArrow = LoadCursor(IntPtr.Zero, (IntPtr)32512);
        _curCross = LoadCursor(IntPtr.Zero, (IntPtr)32515);
        _curNWSE = LoadCursor(IntPtr.Zero, (IntPtr)32642);
        _curNESW = LoadCursor(IntPtr.Zero, (IntPtr)32643);
        _curWE = LoadCursor(IntPtr.Zero, (IntPtr)32644);
        _curNS = LoadCursor(IntPtr.Zero, (IntPtr)32645);
        _curAll = LoadCursor(IntPtr.Zero, (IntPtr)32646);

        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS,
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc),
            hInstance = GetModuleHandle(null),
            hCursor = _curCross,
            lpszClassName = cls,
        };
        RegisterClassEx(ref wc);
        // WS_EX_NOACTIVATE so clicking the overlay never raises it above the control bar (which must
        // stay clickable). Keyboard focus therefore won't arrive, so Esc is polled via a timer.
        _hwnd = CreateWindowEx(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            cls, "", WS_POPUP, 0, 0, _sw, _sh, IntPtr.Zero, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
        if (_hwnd == IntPtr.Zero) { Diag($"CreateWindowEx failed err={Marshal.GetLastWin32Error()}"); return; }

        var screenDc = GetDC(IntPtr.Zero);
        _memDc = CreateCompatibleDC(screenDc);
        var bmi = new BITMAPINFO { biSize = 40, biWidth = _sw, biHeight = -_sh, biPlanes = 1, biBitCount = 32 };
        _dib = CreateDIBSection(screenDc, ref bmi, 0, out _bits, IntPtr.Zero, 0);
        _oldBmp = SelectObject(_memDc, _dib);
        ReleaseDC(IntPtr.Zero, screenDc);

        SetWindowPos(_hwnd, new IntPtr(-1), 0, 0, _sw, _sh, 0x0040 /*SWP_SHOWWINDOW*/);
        ShowWindow(_hwnd, 8 /*SW_SHOWNA*/);
        SetTimer(_hwnd, EscTimerId, 40, IntPtr.Zero); // poll Esc (no keyboard focus with NOACTIVATE)
        Redraw();

        while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }

        // Cleanup
        if (_memDc != IntPtr.Zero) { SelectObject(_memDc, _oldBmp); DeleteDC(_memDc); }
        if (_dib != IntPtr.Zero) DeleteObject(_dib);
        if (_hwnd != IntPtr.Zero) DestroyWindow(_hwnd);
        _hwnd = _memDc = _dib = IntPtr.Zero;

        if (_cancelled) _onCancel();
    }

    private IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case WM_LBUTTONDOWN:
            {
                int x = LoWord(lParam), y = HiWord(lParam);
                if (_rect is null)
                {
                    _op = Op.Creating; _dragX = x; _dragY = y;
                    _rect = new RectI(x, y, 0, 0);
                    SetCapture(hwnd);
                }
                else
                {
                    var z = HitTest(x, y);
                    if (z == Zone.Outside) return IntPtr.Zero; // clicking outside does nothing
                    _orig = _rect.Value; _dragX = x; _dragY = y;
                    if (z == Zone.Inside) _op = Op.Moving;
                    else { _op = Op.Resizing; _resizeZone = z; }
                    SetCapture(hwnd);
                }
                return IntPtr.Zero;
            }

            case WM_MOUSEMOVE:
            {
                int x = Clamp(LoWord(lParam), 0, _sw), y = Clamp(HiWord(lParam), 0, _sh);
                switch (_op)
                {
                    case Op.Creating:
                        _rect = new RectI(Math.Min(_dragX, x), Math.Min(_dragY, y), Math.Abs(x - _dragX), Math.Abs(y - _dragY));
                        Redraw();
                        break;
                    case Op.Moving:
                        int nx = Clamp(_orig.X + (x - _dragX), 0, _sw - _orig.W);
                        int ny = Clamp(_orig.Y + (y - _dragY), 0, _sh - _orig.H);
                        _rect = new RectI(nx, ny, _orig.W, _orig.H);
                        Redraw();
                        break;
                    case Op.Resizing:
                        _rect = Resize(_orig, _resizeZone, x, y);
                        Redraw();
                        break;
                }
                return IntPtr.Zero;
            }

            case WM_LBUTTONUP:
                if (_op != Op.None)
                {
                    _op = Op.None;
                    ReleaseCapture();
                    if (_rect is { } rr && rr.W >= 16 && rr.H >= 16)
                        _onRegion(((double)rr.X / _sw, (double)rr.Y / _sh, (double)rr.W / _sw, (double)rr.H / _sh)); // auto-accept
                    else { _rect = null; Redraw(); } // too small → discard
                }
                return IntPtr.Zero;

            case WM_RBUTTONDOWN:
                _cancelled = true; PostMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                return IntPtr.Zero;

            case WM_KEYDOWN:
                if (wParam.ToInt32() == 0x1B) { _cancelled = true; PostMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); }
                return IntPtr.Zero;

            case WM_TIMER:
                if ((GetAsyncKeyState(0x1B) & 0x8000) != 0) // VK_ESCAPE
                {
                    KillTimer(hwnd, EscTimerId);
                    _cancelled = true;
                    PostMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                }
                return IntPtr.Zero;

            case WM_SETCURSOR:
                SetCursor(CursorFor());
                return (IntPtr)1;

            case WM_CLOSE:
                PostQuitMessage(0);
                return IntPtr.Zero;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private RectI Resize(RectI o, Zone z, int mx, int my)
    {
        const int min = 16;
        int x1 = o.X, y1 = o.Y, x2 = o.X + o.W, y2 = o.Y + o.H;
        if (z is Zone.W or Zone.NW or Zone.SW) x1 = Clamp(mx, 0, x2 - min);
        if (z is Zone.E or Zone.NE or Zone.SE) x2 = Clamp(mx, x1 + min, _sw);
        if (z is Zone.N or Zone.NW or Zone.NE) y1 = Clamp(my, 0, y2 - min);
        if (z is Zone.S or Zone.SW or Zone.SE) y2 = Clamp(my, y1 + min, _sh);
        return new RectI(x1, y1, x2 - x1, y2 - y1);
    }

    private Zone HitTest(int x, int y)
    {
        if (_rect is not { } r) return Zone.Outside;
        const int t = 8;
        bool left = Math.Abs(x - r.X) <= t, right = Math.Abs(x - (r.X + r.W)) <= t;
        bool top = Math.Abs(y - r.Y) <= t, bottom = Math.Abs(y - (r.Y + r.H)) <= t;
        bool inX = x >= r.X - t && x <= r.X + r.W + t;
        bool inY = y >= r.Y - t && y <= r.Y + r.H + t;
        if (!(inX && inY)) return Zone.Outside;
        if (top && left) return Zone.NW;
        if (top && right) return Zone.NE;
        if (bottom && left) return Zone.SW;
        if (bottom && right) return Zone.SE;
        if (top) return Zone.N;
        if (bottom) return Zone.S;
        if (left) return Zone.W;
        if (right) return Zone.E;
        if (x > r.X && x < r.X + r.W && y > r.Y && y < r.Y + r.H) return Zone.Inside;
        return Zone.Outside;
    }

    private IntPtr CursorFor()
    {
        if (_rect is null) return _curCross;
        GetCursorPos(out var p);
        return HitTest(p.X, p.Y) switch
        {
            Zone.N or Zone.S => _curNS,
            Zone.E or Zone.W => _curWE,
            Zone.NW or Zone.SE => _curNWSE,
            Zone.NE or Zone.SW => _curNESW,
            Zone.Inside => _curAll,
            _ => _curCross,
        };
    }

    private void Redraw()
    {
        var buf = OverlayPainter.Build(_sw, _sh, _rect, dimAlpha: 110,
            border: OverlayPainter.BrandBright, borderThickness: 2, grips: _rect is not null);
        Marshal.Copy(buf, 0, _bits, buf.Length);

        // Top-center hint (always visible) so the confirm/cancel gestures are discoverable, drawn
        // with GDI then alpha-corrected so it composites over the dim/desktop.
        DrawHint();

        var screenDc = GetDC(IntPtr.Zero);
        var ptDst = new POINT { X = 0, Y = 0 };
        var size = new SIZE { cx = _sw, cy = _sh };
        var ptSrc = new POINT { X = 0, Y = 0 };
        var blend = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
        bool ok = UpdateLayeredWindow(_hwnd, screenDc, ref ptDst, ref size, _memDc, ref ptSrc, 0, ref blend, 0x2 /*ULW_ALPHA*/);
        if (!ok) Diag($"UpdateLayeredWindow FAILED err={Marshal.GetLastWin32Error()}");
        ReleaseDC(IntPtr.Zero, screenDc);
    }

    private void DrawHint()
    {
        string text = _rect is null
            ? "Drag to select an area      ·      Esc to cancel"
            : "Drag inside to move      ·      drag edges to resize      ·      Esc to cancel";
        SetBkMode(_memDc, 1 /*TRANSPARENT*/);
        SetTextColor(_memDc, 0x00FFFFFF /*white, 0x00BBGGRR*/);
        var font = CreateFont(-24, 0, 0, 0, 600, 0, 0, 0, 1 /*DEFAULT_CHARSET*/, 0, 0, 5 /*CLEARTYPE*/, 0, "Segoe UI");
        var oldFont = SelectObject(_memDc, font);
        // Top-center band, clear of the selection so it never covers the clear region.
        var rc = new RECT { left = 0, top = 48, right = _sw, bottom = 108 };
        DrawText(_memDc, text, -1, ref rc, 0x25 /*DT_CENTER|DT_VCENTER|DT_SINGLELINE*/);
        SelectObject(_memDc, oldFont);
        DeleteObject(font);

        // GDI leaves the alpha byte untouched; rebuild it from the drawn luminance so the text is a
        // correctly premultiplied white overlay (edges anti-aliased). Only the text band is scanned
        // (not the whole screen) so dragging stays responsive.
        const int bandTop = 40, bandBottom = 120;
        int stride = _sw * 4;
        int offset = bandTop * stride;
        int count = Math.Min((bandBottom - bandTop) * stride, _sw * _sh * 4 - offset);
        var tmp = new byte[count];
        Marshal.Copy(IntPtr.Add(_bits, offset), tmp, 0, count);
        for (int i = 0; i < count; i += 4)
        {
            byte m = Math.Max(tmp[i], Math.Max(tmp[i + 1], tmp[i + 2]));
            if (m > tmp[i + 3]) tmp[i + 3] = m; // text pixels become opaque white; dim untouched
        }
        Marshal.Copy(tmp, 0, IntPtr.Add(_bits, offset), count);
    }

    private static void Diag(string msg)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DemoTape", "logs");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "overlay.log"), $"[{DateTimeOffset.Now:HH:mm:ss.fff}] {msg}{Environment.NewLine}");
        }
        catch { }
    }

    private static int Clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
    private static int LoWord(IntPtr v) => unchecked((short)(v.ToInt64() & 0xFFFF));
    private static int HiWord(IntPtr v) => unchecked((short)((v.ToInt64() >> 16) & 0xFFFF));

    // ---- Win32 interop ----
    private delegate IntPtr WndProcDelegate(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    private const uint WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202,
        WM_LBUTTONDBLCLK = 0x0203, WM_RBUTTONDOWN = 0x0204, WM_KEYDOWN = 0x0100,
        WM_SETCURSOR = 0x0020, WM_CLOSE = 0x0010, WM_TIMER = 0x0113;
    private const int WS_POPUP = unchecked((int)0x80000000);
    private const int WS_EX_LAYERED = 0x80000, WS_EX_TOOLWINDOW = 0x80, WS_EX_TOPMOST = 0x8, WS_EX_NOACTIVATE = 0x08000000;
    private const uint CS_VREDRAW = 0x0001, CS_HREDRAW = 0x0002, CS_DBLCLKS = 0x0008;
    private static readonly IntPtr EscTimerId = new(1);

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] private struct SIZE { public int cx; public int cy; }
    [StructLayout(LayoutKind.Sequential)]
    private struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }
    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFO
    {
        public int biSize; public int biWidth; public int biHeight; public short biPlanes; public short biBitCount;
        public int biCompression; public int biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public int biClrUsed; public int biClrImportant; public int colors;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX
    {
        public int cbSize; public uint style; public IntPtr lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        public string? lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern ushort RegisterClassEx(ref WNDCLASSEX wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(int exStyle, string className, string windowName, int style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("user32.dll")] private static extern IntPtr SetCapture(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern IntPtr LoadCursor(IntPtr hInstance, IntPtr lpCursorName);
    [DllImport("user32.dll")] private static extern IntPtr SetCursor(IntPtr hCursor);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] private static extern IntPtr SetTimer(IntPtr hwnd, IntPtr id, uint elapse, IntPtr func);
    [DllImport("user32.dll")] private static extern bool KillTimer(IntPtr hwnd, IntPtr id);
    [DllImport("user32.dll")] private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
        IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, uint dwFlags);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] private static extern int SetBkMode(IntPtr hdc, int mode);
    [DllImport("gdi32.dll")] private static extern uint SetTextColor(IntPtr hdc, uint color);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFont(int height, int width, int esc, int orient, int weight, uint italic,
        uint underline, uint strike, uint charset, uint outPrec, uint clipPrec, uint quality, uint pitch, string face);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int DrawText(IntPtr hdc, string text, int count, ref RECT rect, uint format);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? name);

    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int left; public int top; public int right; public int bottom; }
}
