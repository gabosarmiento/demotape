using System;
using System.Runtime.InteropServices;
using DemoTape.Domain.Settings;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>
/// A top-of-screen teleprompter: a dark panel with the script slowly scrolling up while you record.
/// Always-on-top and excluded from screen capture (WDA_EXCLUDEFROMCAPTURE), so you can read it but
/// it never appears in the video. Windows analogue of the macOS teleprompter overlay.
/// </summary>
public sealed partial class TeleprompterWindow : Window
{
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherQueueTimer _timer;
    private readonly double _speed;
    private double _offset;

    public TeleprompterWindow(AppSettings settings)
    {
        InitializeComponent();
        _speed = Math.Max(5, settings.TeleprompterSpeed);
        ScriptText.Text = string.IsNullOrWhiteSpace(settings.TeleprompterScript)
            ? "(No script — add one in Teleprompter Settings.)" : settings.TeleprompterScript;
        ScriptText.FontSize = Math.Clamp(settings.TeleprompterFontSize, 12, 60);

        ConfigureWindow();

        _timer = _dispatcher.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(33);
        _timer.Tick += (_, _) =>
        {
            _offset += _speed * 0.033;
            var max = Math.Max(0, Scroller.ScrollableHeight);
            if (max > 0 && _offset > max) _offset = 0; // loop
            Scroller.ChangeView(null, _offset, null, disableAnimation: true);
        };
        Activated += (_, _) => { };
        Closed += (_, _) => _timer.Stop();
        _timer.Start();
    }

    private void ConfigureWindow()
    {
        var hwnd = WindowNative.GetWindowHandle(this);
        var id = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = AppWindow.GetFromWindowId(id);
        if (appWindow.Presenter is OverlappedPresenter p)
        {
            p.SetBorderAndTitleBar(false, false);
            p.IsAlwaysOnTop = true;
            p.IsResizable = false; p.IsMaximizable = false; p.IsMinimizable = false;
        }
        appWindow.IsShownInSwitchers = false;

        var area = DisplayArea.GetFromWindowId(id, DisplayAreaFallback.Primary);
        var wa = area.WorkArea;
        int w = (int)(wa.Width * 0.6), h = 180;
        appWindow.Resize(new SizeInt32(w, h));
        appWindow.Move(new PointInt32(wa.X + (wa.Width - w) / 2, wa.Y + 24));

        SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
    }

    private const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    [DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
}
