using System.Runtime.InteropServices;
using DemoTape.Domain.Abstractions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;
using Windows.System;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>
/// Full-screen drag-to-select overlay for choosing a recording region. The Windows analogue of the
/// macOS <c>RegionSelector</c>. On release it saves the region (normalized to the screen, top-left
/// origin) to settings and switches capture into region mode.
/// </summary>
public sealed partial class RegionSelectorWindow : Window
{
    private readonly ISettingsStore _settingsStore;
    private Point? _start;
    private bool _committed;

    public RegionSelectorWindow(ISettingsStore settingsStore)
    {
        _settingsStore = settingsStore;
        InitializeComponent();

        var hwnd = WindowNative.GetWindowHandle(this);
        MakeFullScreenOverlay(hwnd);

        Root.PointerPressed += OnPressed;
        Root.PointerMoved += OnMoved;
        Root.PointerReleased += OnReleased;
        Root.KeyDown += OnKeyDown;
        Root.Loaded += (_, _) => Root.Focus(FocusState.Programmatic);
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        _start = e.GetCurrentPoint(Root).Position;
        Root.CapturePointer(e.Pointer);
        SelRect.Visibility = Visibility.Visible;
        DimText.Visibility = Visibility.Visible;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_start is null) return;
        var p = e.GetCurrentPoint(Root).Position;
        var (x, y, w, h) = Normalize(_start.Value, p);
        Canvas.SetLeft(SelRect, x); Canvas.SetTop(SelRect, y);
        SelRect.Width = w; SelRect.Height = h;
        DimText.Text = $"{(int)w} × {(int)h}";
        Canvas.SetLeft(DimText, x + 4); Canvas.SetTop(DimText, Math.Max(0, y - 22));
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_start is null) return;
        Root.ReleasePointerCapture(e.Pointer);
        var end = e.GetCurrentPoint(Root).Position;
        var (x, y, w, h) = Normalize(_start.Value, end);
        _start = null;

        double totalW = Root.ActualWidth, totalH = Root.ActualHeight;
        if (w < 20 || h < 20 || totalW <= 0 || totalH <= 0) { Close(); return; } // too small → cancel

        var s = _settingsStore.Load();
        s.RegionX = x / totalW;
        s.RegionY = y / totalH;
        s.RegionW = w / totalW;
        s.RegionH = h / totalH;
        s.UseRegion = true;
        _settingsStore.Save(s);
        _committed = true;
        Close();
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape) Close();
    }

    /// <summary>Whether the user confirmed a region (vs cancelled).</summary>
    public bool Committed => _committed;

    private static (double x, double y, double w, double h) Normalize(Point a, Point b)
        => (Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));

    private static void MakeFullScreenOverlay(IntPtr hwnd)
    {
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_TOOLWINDOW);
        SetWindowLong(hwnd, GWL_STYLE, WS_POPUP | WS_VISIBLE);
        int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN);
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, w, h, SWP_SHOWWINDOW);
    }

    private const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    private const int WS_POPUP = unchecked((int)0x80000000), WS_VISIBLE = 0x10000000, WS_EX_TOOLWINDOW = 0x80;
    private const int SM_CXSCREEN = 0, SM_CYSCREEN = 1;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private static readonly IntPtr HWND_TOPMOST = new(-1);

    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
