using System;
using System.Runtime.InteropServices;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Settings;
using DemoTape.ViewModels;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
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
    private readonly INavigationService? _navigation;
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherQueueTimer _timer;
    private DateTimeOffset _recordStart;

    public ControlBarWindow(IRecordingController controller, ISettingsStore settings,
        INavigationService? navigation = null)
    {
        _controller = controller;
        _settings = settings;
        _navigation = navigation;
        InitializeComponent();

        var s = settings.Load();
        MicBtn.IsChecked = s.CaptureMicrophone;
        CamBtn.IsChecked = s.CaptureWebcam;
        SyncToggleVisual(MicBtn, MicIcon, MicStrike);
        SyncToggleVisual(CamBtn, CamIcon, CamStrike);

        BuildSetupMenu();

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

        const int w = 424, h = 56;
        appWindow.Resize(new SizeInt32(w, h));
        var area = DisplayArea.GetFromWindowId(id, DisplayAreaFallback.Primary);
        var wa = area.WorkArea;
        appWindow.Move(new PointInt32(wa.X + wa.Width - w - 24, wa.Y + wa.Height - h - 24));

        // Keep the bar out of the recording (visible on-screen, excluded from screen capture).
        SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
    }

    /// <summary>
    /// The ellipsis "•••" setup flyout — the recording options you'd change just before a take,
    /// right on the bar instead of only under the tray icon. This is a second door onto the same
    /// settings/navigation the tray menu uses, so the two never drift apart. Toggles keep the menu
    /// open (you often flip two); anything that opens a window closes it first.
    /// </summary>
    private void BuildSetupMenu()
    {
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.Top };

        // Capture mode (radio) — Full Screen / Select Area, driven straight through the controller.
        var fullScreen = new RadioMenuFlyoutItem { Text = "Full Screen", GroupName = "barCaptureMode" };
        fullScreen.Click += async (_, _) => await _controller.ArmFullScreenAsync();
        var selectArea = new RadioMenuFlyoutItem { Text = "Select Recording Area…", GroupName = "barCaptureMode" };
        selectArea.Click += async (_, _) => await _controller.ArmRegionAsync();
        menu.Items.Add(fullScreen);
        menu.Items.Add(selectArea);
        menu.Items.Add(new MenuFlyoutSeparator());

        // Background (opens the picker window).
        var background = new MenuFlyoutItem { Text = "Background…" };
        background.Click += (_, _) => _navigation?.OpenBackgroundPicker();
        menu.Items.Add(background);

        // Branding — a toggle plus its settings window.
        var branding = MakeToggle("Branding", s => s.BrandingEnabled, (s, v) => s.BrandingEnabled = v);
        var brandingSettings = new MenuFlyoutItem { Text = "Branding Settings…" };
        brandingSettings.Click += (_, _) => _navigation?.OpenBrandingSettings();
        menu.Items.Add(branding);
        menu.Items.Add(brandingSettings);

        // Teleprompter — a toggle plus its settings window.
        var teleprompter = MakeToggle("Teleprompter", s => s.TeleprompterEnabled, (s, v) => s.TeleprompterEnabled = v);
        var teleSettings = new MenuFlyoutItem { Text = "Teleprompter Settings…" };
        teleSettings.Click += (_, _) => _navigation?.OpenTeleprompterSettings();
        menu.Items.Add(teleprompter);
        menu.Items.Add(teleSettings);

        // Auto-Zoom.
        var autoZoom = MakeToggle("Auto-Zoom", s => s.AutoZoom, (s, v) => s.AutoZoom = v);
        menu.Items.Add(autoZoom);
        menu.Items.Add(new MenuFlyoutSeparator());

        // Mic clean-up — both apply in every capture mode.
        var enhance = MakeToggle("Enhance Voice", s => s.EnhanceVoice, (s, v) => s.EnhanceVoice = v);
        var noise = MakeToggle("Smart Noise Suppression", s => s.NoiseSuppression, (s, v) => s.NoiseSuppression = v);
        menu.Items.Add(enhance);
        menu.Items.Add(noise);

        var webcam = new MenuFlyoutItem { Text = "Webcam Settings…" };
        webcam.Click += (_, _) => _navigation?.OpenWebcamSettings();
        menu.Items.Add(webcam);
        menu.Items.Add(new MenuFlyoutSeparator());

        var ai = new MenuFlyoutItem { Text = "AI Settings…" };
        ai.Click += (_, _) => _navigation?.OpenAiSettings();
        menu.Items.Add(ai);

        // Re-read persisted state each time the menu opens, so it always shows the truth (the tray
        // menu, region selector, etc. write the same settings.json).
        menu.Opening += (_, _) =>
        {
            var s = _settings.Load();
            fullScreen.IsChecked = !s.UseRegion;
            selectArea.IsChecked = s.UseRegion;
            branding.IsChecked = s.BrandingEnabled;
            teleprompter.IsChecked = s.TeleprompterEnabled;
            autoZoom.IsChecked = s.AutoZoom;
            enhance.IsChecked = s.EnhanceVoice;
            noise.IsChecked = s.NoiseSuppression;
        };

        SetupBtn.Flyout = menu;
    }

    private ToggleMenuFlyoutItem MakeToggle(string text,
        Func<AppSettings, bool> get, Action<AppSettings, bool> set)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = get(_settings.Load()) };
        item.Click += (_, _) =>
        {
            var s = _settings.Load();
            set(s, item.IsChecked);
            _settings.Save(s);
        };
        return item;
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
