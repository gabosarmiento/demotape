using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// A full-screen, per-pixel-alpha overlay window drawn with <c>UpdateLayeredWindow</c>. Unlike a
/// WinUI window (which is opaque and can only do a uniform alpha), this composites a true 32bpp
/// premultiplied BGRA bitmap over the live desktop — so a semi-transparent dim actually lets you
/// see what's underneath, and a punched-out region stays perfectly clear. This is how the native
/// Windows snip/record overlay achieves its look.
/// </summary>
public abstract class LayeredOverlay : IDisposable
{
    private const string ClassName = "DemoTapeLayeredOverlay";
    private static readonly WndProcDelegate SharedProc = StaticWndProc;
    private static readonly ConcurrentDictionary<IntPtr, LayeredOverlay> Instances = new();
    private static bool _classRegistered;

    protected int Width { get; }
    protected int Height { get; }
    private IntPtr _hwnd;
    private IntPtr _memDc;
    private IntPtr _dib;
    private IntPtr _oldBitmap;
    private IntPtr _bits;
    private bool _disposed;

    protected LayeredOverlay(bool clickThrough)
    {
        Width = GetSystemMetrics(SM_CXSCREEN);
        Height = GetSystemMetrics(SM_CYSCREEN);
        EnsureClass();

        int exStyle = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE;
        if (clickThrough) exStyle |= WS_EX_TRANSPARENT;

        _hwnd = CreateWindowEx(exStyle, ClassName, "", WS_POPUP,
            0, 0, Width, Height, IntPtr.Zero, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
        Instances[_hwnd] = this;

        // Top-down 32bpp DIB section we render into, then blit to the screen via UpdateLayeredWindow.
        var screenDc = GetDC(IntPtr.Zero);
        _memDc = CreateCompatibleDC(screenDc);
        var bmi = new BITMAPINFO
        {
            biSize = Marshal.SizeOf<BITMAPINFOHEADER>(),
            biWidth = Width,
            biHeight = -Height, // negative => top-down
            biPlanes = 1,
            biBitCount = 32,
            biCompression = 0, // BI_RGB
        };
        _dib = CreateDIBSection(screenDc, ref bmi, 0 /* DIB_RGB_COLORS */, out _bits, IntPtr.Zero, 0);
        _oldBitmap = SelectObject(_memDc, _dib);
        ReleaseDC(IntPtr.Zero, screenDc);

        SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, Width, Height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    /// <summary>Pushes a premultiplied BGRA buffer (top-down, Width*Height*4) to the screen.</summary>
    protected void Present(byte[] bgraPremultiplied)
    {
        if (_disposed || _bits == IntPtr.Zero) return;
        Marshal.Copy(bgraPremultiplied, 0, _bits, Math.Min(bgraPremultiplied.Length, Width * Height * 4));

        var screenDc = GetDC(IntPtr.Zero);
        var ptDst = new POINT { X = 0, Y = 0 };
        var size = new SIZE { cx = Width, cy = Height };
        var ptSrc = new POINT { X = 0, Y = 0 };
        var blend = new BLENDFUNCTION
        {
            BlendOp = 0,      // AC_SRC_OVER
            BlendFlags = 0,
            SourceConstantAlpha = 255,
            AlphaFormat = 1,  // AC_SRC_ALPHA (use the bitmap's per-pixel alpha)
        };
        UpdateLayeredWindow(_hwnd, screenDc, ref ptDst, ref size, _memDc, ref ptSrc, 0, ref blend, ULW_ALPHA);
        ReleaseDC(IntPtr.Zero, screenDc);
    }

    /// <summary>Subclass hook for window messages. Return a value to handle; null to defer to default.</summary>
    protected virtual IntPtr? OnMessage(uint msg, IntPtr wParam, IntPtr lParam) => null;

    protected IntPtr Handle => _hwnd;

    protected void Capture() => SetCapture(_hwnd);
    protected void ReleaseCaptureInternal() => ReleaseCapture();

    /// <summary>Makes this window invisible to screen capture (still visible on screen).</summary>
    protected void ExcludeFromCapture()
    {
        if (_hwnd != IntPtr.Zero) SetWindowDisplayAffinity(_hwnd, WDA_EXCLUDEFROMCAPTURE);
    }

    private static IntPtr StaticWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (Instances.TryGetValue(hwnd, out var self))
        {
            var handled = self.OnMessage(msg, wParam, lParam);
            if (handled.HasValue) return handled.Value;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private static void EnsureClass()
    {
        if (_classRegistered) return;
        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            style = 0,
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(SharedProc),
            hInstance = GetModuleHandle(null),
            hCursor = LoadCursor(IntPtr.Zero, IDC_CROSS),
            lpszClassName = ClassName,
        };
        RegisterClassEx(ref wc);
        _classRegistered = true;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_hwnd != IntPtr.Zero) Instances.TryRemove(_hwnd, out _);
        if (_memDc != IntPtr.Zero)
        {
            if (_oldBitmap != IntPtr.Zero) SelectObject(_memDc, _oldBitmap);
            DeleteDC(_memDc);
        }
        if (_dib != IntPtr.Zero) DeleteObject(_dib);
        if (_hwnd != IntPtr.Zero) DestroyWindow(_hwnd);
        _hwnd = _memDc = _dib = _oldBitmap = _bits = IntPtr.Zero;
        GC.SuppressFinalize(this);
    }

    // ---- helpers for extracting mouse coords ----
    protected static int LoWord(IntPtr v) => unchecked((short)(v.ToInt64() & 0xFFFF));
    protected static int HiWord(IntPtr v) => unchecked((short)((v.ToInt64() >> 16) & 0xFFFF));

    // ---- Win32 interop ----
    private delegate IntPtr WndProcDelegate(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    private const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80,
        WS_EX_TOPMOST = 0x8, WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_POPUP = unchecked((int)0x80000000);
    private const int SM_CXSCREEN = 0, SM_CYSCREEN = 1;
    private const uint SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;
    private const uint ULW_ALPHA = 0x2;
    private const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private static readonly IntPtr IDC_CROSS = new(32515);

    [StructLayout(LayoutKind.Sequential)] protected struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] private struct SIZE { public int cx; public int cy; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public int biSize; public int biWidth; public int biHeight; public short biPlanes; public short biBitCount;
        public int biCompression; public int biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public int biClrUsed; public int biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFO
    {
        public int biSize; public int biWidth; public int biHeight; public short biPlanes; public short biBitCount;
        public int biCompression; public int biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public int biClrUsed; public int biClrImportant;
        // color table (unused for 32bpp BI_RGB)
        public int colors;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX
    {
        public int cbSize; public uint style; public IntPtr lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        public string? lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }

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
    [DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
    [DllImport("user32.dll")]
    private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
        IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, uint dwFlags);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? name);
}
