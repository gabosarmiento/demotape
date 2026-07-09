using System;
using System.Runtime.InteropServices;
using DemoTape.Domain.Abstractions;
using DemoTape.ViewModels;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Windows.Graphics;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>
/// A small floating control bar (bottom-right) that drives a recording session: Start/Stop, a live
/// timer, mic/webcam toggles, and Cancel. Shown while a capture is armed or in progress. This is
/// the DemoTape-native alternative to the OS capture bar, wired to the recording controller.
/// </summary>
public sealed partial class ControlBarWindow : Window
{
    private readonly IRecordingController _controller;
    private readonly ISettingsStore _settings;
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherQueueTimer _timer;
    private DateTimeOffset _recordStart;

    public ControlBarWindow(IRecordingController controller, ISettingsStore settings)
    {
        _controller = controller;
        _settings = settings;
        InitializeComponent();

        var s = settings.Load();
        MicBtn.IsChecked = s.CaptureMicrophone;
        CamBtn.IsChecked = s.CaptureWebcam;
        SyncToggleVisual(MicBtn, MicIcon, MicStrike);
        SyncToggleVisual(CamBtn, CamIcon, CamStrike);

        LeftDrag.PointerPressed += OnDragPressed;
        RightDrag.PointerPressed += OnDragPressed;

        ConfigureWindow();
        ApplyState(_controller.State);
        _controller.StateChanged += OnStateChanged;

        _timer = _dispatcher.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(250);
        _timer.Tick += (_, _) =>
        {
            var t = DateTimeOffset.Now - _recordStart;
            TimerText.Text = $"{(int)t.TotalMinutes:00}:{t.Seconds:00}";
        };

        Closed += (_, _) => _controller.StateChanged -= OnStateChanged;
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
            p.IsResizable = false;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
        }
        appWindow.IsShownInSwitchers = false;

        const int w = 380, h = 56;
        appWindow.Resize(new SizeInt32(w, h));
        var area = DisplayArea.GetFromWindowId(id, DisplayAreaFallback.Primary);
        var wa = area.WorkArea;
        appWindow.Move(new PointInt32(wa.X + wa.Width - w - 24, wa.Y + wa.Height - h - 24));

        // Keep the bar out of the recording (visible on-screen, excluded from screen capture).
        SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
    }

    private void OnDragPressed(object sender, PointerRoutedEventArgs e)
    {
        // Initiate the standard window-move loop so the bar can be dropped anywhere on screen.
        var hwnd = WindowNative.GetWindowHandle(this);
        ReleaseCapture();
        SendMessage(hwnd, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
    }

    private void OnStateChanged(RecordingState s) => _dispatcher.TryEnqueue(() => ApplyState(s));

    private void ApplyState(RecordingState s)
    {
        switch (s)
        {
            case RecordingState.Armed:
                RecLabel.Text = "Start";
                RecDot.Fill = new Microsoft.UI.Xaml.Media.SolidColorBrush(Colors.White);
                RecordBtn.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(ColorHelper.FromArgb(0xFF, 0x22, 0xB0, 0xE6)); // brand blue
                TimerText.Visibility = Visibility.Collapsed;
                _timer?.Stop();
                break;
            case RecordingState.Countdown:
                RecLabel.Text = "…";
                break;
            case RecordingState.Recording:
                RecLabel.Text = "Stop";
                RecordBtn.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(ColorHelper.FromArgb(0xFF, 0xE5, 0x39, 0x35)); // red = stop
                TimerText.Visibility = Visibility.Visible;
                _recordStart = DateTimeOffset.Now;
                TimerText.Text = "00:00";
                _timer?.Start();
                break;
            case RecordingState.Rendering:
            case RecordingState.Idle:
                _timer?.Stop();
                break;
        }
    }

    private async void OnRecord(object sender, RoutedEventArgs e)
    {
        switch (_controller.State)
        {
            case RecordingState.Armed: await _controller.StartAsync(); break;
            case RecordingState.Recording: await _controller.StopAsync(); break;
        }
    }

    private async void OnCancel(object sender, RoutedEventArgs e) => await _controller.CancelAsync();

    private void OnToggleMic(object sender, RoutedEventArgs e)
    {
        var s = _settings.Load();
        s.CaptureMicrophone = MicBtn.IsChecked == true;
        _settings.Save(s);
        SyncToggleVisual(MicBtn, MicIcon, MicStrike);
    }

    private void OnToggleCam(object sender, RoutedEventArgs e)
    {
        var s = _settings.Load();
        s.CaptureWebcam = CamBtn.IsChecked == true;
        _settings.Save(s);
        SyncToggleVisual(CamBtn, CamIcon, CamStrike);
    }

    // Same icon in both states; a diagonal strike + gray indicates "disabled" (white = enabled).
    private static void SyncToggleVisual(Microsoft.UI.Xaml.Controls.Primitives.ToggleButton btn,
        Microsoft.UI.Xaml.Controls.FontIcon icon, Microsoft.UI.Xaml.Shapes.Line strike)
    {
        bool on = btn.IsChecked == true;
        strike.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        icon.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
            on ? Colors.White                                    // white = active (clear + legible)
               : ColorHelper.FromArgb(0xFF, 0x8A, 0x8A, 0x8E));  // gray = disabled
    }

    private const uint WM_NCLBUTTONDOWN = 0x00A1, WDA_EXCLUDEFROMCAPTURE = 0x11;
    private const int HTCAPTION = 2;

    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
}
