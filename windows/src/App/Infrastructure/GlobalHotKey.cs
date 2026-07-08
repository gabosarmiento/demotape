using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Registers a system-wide hotkey via Win32 <c>RegisterHotKey</c> against a hidden
/// message-only window, mirroring the macOS Carbon <c>GlobalHotKey</c>. The chord is consumed
/// system-wide so it won't leak into the focused app or the recording.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class GlobalHotKey : IDisposable
{
    [Flags]
    public enum Modifiers : uint { Alt = 0x1, Control = 0x2, Shift = 0x4, Win = 0x8, NoRepeat = 0x4000 }

    public event Action? Pressed;

    private const int WmHotkey = 0x0312;
    private const int HotkeyId = 0xB00B;

    private IntPtr _hwnd;
    private Thread? _thread;
    private uint _threadId;
    private WndProc? _wndProc;
    private readonly Modifiers _mods;
    private readonly uint _vk;

    /// <summary>Creates a hotkey for the given modifiers + virtual-key. Default Ctrl+Shift+R.</summary>
    public GlobalHotKey(Modifiers mods = Modifiers.Control | Modifiers.Shift, uint virtualKey = 0x52 /* 'R' */)
    {
        _mods = mods | Modifiers.NoRepeat;
        _vk = virtualKey;
    }

    /// <summary>Starts the message loop and registers the hotkey.</summary>
    public void Register()
    {
        _thread = new Thread(Run) { IsBackground = true, Name = "DemoTape.HotKey" };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
    }

    private void Run()
    {
        _threadId = GetCurrentThreadId();
        _wndProc = WindowProc;
        var wc = new WNDCLASS
        {
            lpszClassName = "DemoTapeHotKeyWindow",
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
        };
        RegisterClass(ref wc);
        _hwnd = CreateWindowEx(0, wc.lpszClassName, "", 0, 0, 0, 0, 0,
            HWND_MESSAGE, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        RegisterHotKey(_hwnd, HotkeyId, (uint)_mods, _vk);

        while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    private IntPtr WindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WmHotkey && wParam.ToInt32() == HotkeyId)
            Pressed?.Invoke();
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hwnd != IntPtr.Zero)
        {
            UnregisterHotKey(_hwnd, HotkeyId);
            DestroyWindow(_hwnd);
            _hwnd = IntPtr.Zero;
        }
        if (_threadId != 0) PostThreadMessage(_threadId, 0x0012 /* WM_QUIT */, IntPtr.Zero, IntPtr.Zero);
    }

    // ---- Win32 interop ----

    private static readonly IntPtr HWND_MESSAGE = new(-3);

    private delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct WNDCLASS
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
        public uint time; public int pt_x; public int pt_y;
    }

    [DllImport("user32.dll", SetLastError = true)] private static extern ushort RegisterClass(ref WNDCLASS lpWndClass);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowEx(uint exStyle, string className, string windowName, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll")] private static extern int GetMessage(out MSG lpMsg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint threadId, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
}
