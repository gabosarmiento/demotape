using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using System.Text.Json;
using DemoTape.Domain.Input;
using DemoTape.Domain.Models;
using Microsoft.Extensions.Logging;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Captures a timeline of cursor movement, clicks, scrolls, and keystrokes during a recording
/// using Win32 low-level hooks (<c>WH_MOUSE_LL</c>/<c>WH_KEYBOARD_LL</c>) plus a fixed-rate
/// cursor sampler. The Windows analogue of the macOS <c>EventRecorder</c>. Unlike macOS,
/// keystroke capture needs no special permission. Writes the same <c>*.events.json</c> sidecar.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class EventRecorder
{
    private const int SampleRateHz = 60;

    private readonly ILogger<EventRecorder> _logger;
    private readonly object _lock = new();
    private readonly Stopwatch _clock = new();

    private readonly List<CursorSample> _cursor = new();
    private readonly List<ClickSample> _clicks = new();
    private readonly List<ScrollSample> _scrolls = new();
    private readonly List<KeySample> _keys = new();

    private double _regionX, _regionY, _regionW, _regionH; // pixels
    private DisplayInfo _display = new();

    private Thread? _hookThread;
    private uint _hookThreadId;
    private IntPtr _mouseHook, _keyboardHook;
    private LowLevelProc? _mouseProc, _keyProc; // keep delegates alive
    private CancellationTokenSource? _samplerCts;

    public EventRecorder(ILogger<EventRecorder> logger) => _logger = logger;

    /// <summary>Begins capture. <paramref name="region"/> is the captured area in screen pixels.</summary>
    public void Start((double X, double Y, double W, double H) region, DisplayInfo display)
    {
        lock (_lock)
        {
            _cursor.Clear(); _clicks.Clear(); _scrolls.Clear(); _keys.Clear();
        }
        (_regionX, _regionY, _regionW, _regionH) = region;
        _display = display;
        _clock.Restart();

        _hookThread = new Thread(HookLoop) { IsBackground = true, Name = "DemoTape.Events" };
        _hookThread.SetApartmentState(ApartmentState.STA);
        _hookThread.Start();

        StartSampler();
        _logger.LogInformation("EventRecorder started (region {W}x{H})", _regionW, _regionH);
    }

    /// <summary>Stops capture and writes the JSON sidecar next to the given video file.</summary>
    public string? Stop(string videoPath, double cameraOffset = 0, double eventOffset = 0)
    {
        _samplerCts?.Cancel();
        if (_hookThreadId != 0) PostThreadMessage(_hookThreadId, 0x0012 /* WM_QUIT */, IntPtr.Zero, IntPtr.Zero);
        _hookThread?.Join(TimeSpan.FromSeconds(1));
        double duration = _clock.Elapsed.TotalSeconds;

        RecordingMetadata meta;
        lock (_lock)
        {
            // Drop the stop hotkey (Ctrl+Shift+R) so it doesn't render as a badge at the very end.
            _keys.RemoveAll(k => k.KeyCode == 0x52 && k.Modifiers.Contains("ctrl") && k.Modifiers.Contains("shift"));
            meta = new RecordingMetadata
            {
                StartedAt = DateTimeOffset.Now,
                Duration = duration,
                CapturedKeystrokes = true,
                CameraStartOffset = cameraOffset,
                EventTimeOffset = eventOffset,
                Display = _display,
                Cursor = new(_cursor),
                Clicks = new(_clicks),
                Scrolls = new(_scrolls),
                Keys = new(_keys),
            };
        }

        var sidecar = StripExt(videoPath) + ".events.json";
        try
        {
            var json = JsonSerializer.Serialize(meta, new JsonSerializerOptions
            {
                WriteIndented = true,
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            });
            File.WriteAllText(sidecar, json);
            _logger.LogInformation("EventRecorder wrote {Name} cursor={C} clicks={K} keys={Y}",
                Path.GetFileName(sidecar), meta.Cursor.Count, meta.Clicks.Count, meta.Keys.Count);
            return sidecar;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to write sidecar");
            return null;
        }
    }

    private void StartSampler()
    {
        _samplerCts = new CancellationTokenSource();
        var ct = _samplerCts.Token;
        _ = Task.Run(async () =>
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1.0 / SampleRateHz));
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                if (!GetCursorPos(out var p)) continue;
                var (x, y) = InputMapping.Normalize(p.X, p.Y, _regionX, _regionY, _regionW, _regionH);
                double t = _clock.Elapsed.TotalSeconds;
                lock (_lock) _cursor.Add(new CursorSample { T = t, X = x, Y = y });
            }
        }, ct);
    }

    // ---- Hook thread + message pump ----

    private void HookLoop()
    {
        _hookThreadId = GetCurrentThreadId();
        _mouseProc = MouseProc;
        _keyProc = KeyboardProc;
        var hInstance = GetModuleHandle(null);
        _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, hInstance, 0);
        _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, _keyProc, hInstance, 0);

        while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }

        if (_mouseHook != IntPtr.Zero) UnhookWindowsHookEx(_mouseHook);
        if (_keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(_keyboardHook);
        _mouseHook = _keyboardHook = IntPtr.Zero;
    }

    private IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var data = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
            double t = _clock.Elapsed.TotalSeconds;
            var (x, y) = InputMapping.Normalize(data.pt.X, data.pt.Y, _regionX, _regionY, _regionW, _regionH);
            int msg = wParam.ToInt32();
            switch (msg)
            {
                case WM_LBUTTONDOWN:
                    lock (_lock) _clicks.Add(new ClickSample { T = t, X = x, Y = y, Button = "left" });
                    break;
                case WM_RBUTTONDOWN:
                    lock (_lock) _clicks.Add(new ClickSample { T = t, X = x, Y = y, Button = "right" });
                    break;
                case WM_MBUTTONDOWN:
                    lock (_lock) _clicks.Add(new ClickSample { T = t, X = x, Y = y, Button = "other" });
                    break;
                case WM_MOUSEWHEEL:
                    short delta = (short)((data.mouseData >> 16) & 0xffff);
                    lock (_lock) _scrolls.Add(new ScrollSample { T = t, X = x, Y = y, Dx = 0, Dy = delta });
                    break;
            }
        }
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    private IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && wParam.ToInt32() == WM_KEYDOWN)
        {
            var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            double t = _clock.Elapsed.TotalSeconds;
            var mods = CurrentModifiers();
            lock (_lock)
            {
                _keys.Add(new KeySample
                {
                    T = t,
                    KeyCode = (int)data.vkCode,
                    Chars = CharFor(data.vkCode),
                    Modifiers = InputMapping.Modifiers(mods),
                });
            }
        }
        return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    private static InputMapping.Mod CurrentModifiers()
    {
        var m = InputMapping.Mod.None;
        if (IsDown(VK_CONTROL)) m |= InputMapping.Mod.Ctrl;
        if (IsDown(VK_SHIFT)) m |= InputMapping.Mod.Shift;
        if (IsDown(VK_MENU)) m |= InputMapping.Mod.Alt;
        if (IsDown(VK_LWIN) || IsDown(VK_RWIN)) m |= InputMapping.Mod.Win;
        return m;
    }

    private static bool IsDown(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

    private static string CharFor(uint vk)
    {
        var buffer = new StringBuilder(4);
        var keyboardState = new byte[256];
        GetKeyboardState(keyboardState);
        uint scan = MapVirtualKey(vk, 0);
        int rc = ToUnicode(vk, scan, keyboardState, buffer, buffer.Capacity, 0);
        return rc > 0 ? buffer.ToString() : "";
    }

    private static string StripExt(string path)
    {
        if (path.EndsWith(".styled.mp4", StringComparison.OrdinalIgnoreCase))
            return path[..^".styled.mp4".Length];
        return Path.Combine(Path.GetDirectoryName(path) ?? "", Path.GetFileNameWithoutExtension(path));
    }

    // ---- Win32 interop ----

    private const int WH_MOUSE_LL = 14, WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_LBUTTONDOWN = 0x0201, WM_RBUTTONDOWN = 0x0204, WM_MBUTTONDOWN = 0x0207, WM_MOUSEWHEEL = 0x020A;
    private const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C;

    private delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }

    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] private static extern bool GetKeyboardState(byte[] lpKeyState);
    [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint uCode, uint uMapType);
    [DllImport("user32.dll")] private static extern int ToUnicode(uint wVirtKey, uint wScanCode, byte[] lpKeyState, StringBuilder pwszBuff, int cchBuff, uint wFlags);
    [DllImport("user32.dll")] private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? lpModuleName);
}
