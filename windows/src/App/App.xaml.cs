using System.IO;
using CommunityToolkit.Mvvm.Input;
using DemoTape.App.Infrastructure;
using DemoTape.ViewModels;
using H.NotifyIcon;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace DemoTape.App;

/// <summary>
/// Application entry point and composition root. Mirrors the macOS <c>AppDelegate</c>: a
/// tray-only (no main window) app that wires a system-tray menu to the <see cref="ShellViewModel"/>
/// and registers a global record-toggle hotkey. Also honors headless CLI hooks
/// (<c>--transcode</c>, <c>--publish</c>) for testing the encode pipeline without a GUI.
/// </summary>
public partial class App : Application
{
    private IServiceProvider _services = null!;
    private TaskbarIcon? _trayIcon;
    private GlobalHotKey? _hotKey;
    private ShellViewModel? _shell;

    public App()
    {
        InitializeComponent();

        // Global crash logging so failures are never silent.
        UnhandledException += (_, e) => LogFatal("UI", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogFatal("Domain", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) => { LogFatal("Task", e.Exception); e.SetObserved(); };
    }

    private static void LogFatal(string source, Exception? ex)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DemoTape", "logs");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "fatal.log"),
                $"[{DateTimeOffset.Now:O}] {source}: {ex}{Environment.NewLine}");
        }
        catch { /* best effort */ }
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var cli = Environment.GetCommandLineArgs();
        if (await HeadlessCli.TryRunAsync(cli))
        {
            Environment.Exit(0);
            return;
        }

        _services = BuildServices();
        _shell = _services.GetRequiredService<ShellViewModel>();

        // A persistent, hidden host window keeps the process alive. Without it, WinUI exits when
        // the last activated window (e.g. Web Publish) is closed — but this is a tray app, so
        // closing an option window must not quit it. It's activated (so it counts as an open
        // window) then immediately hidden from screen and alt-tab.
        _hostWindow = new Window();
        _hostWindow.AppWindow.IsShownInSwitchers = false;
        _hostWindow.Activate();
        var hostHwnd = WinRT.Interop.WindowNative.GetWindowHandle(_hostWindow);
        ShowWindow(hostHwnd, SW_HIDE);

        CreateTrayIcon(_shell);
        RegisterHotKey(_shell);
    }

    private Window? _hostWindow;
    private const int SW_HIDE = 0;
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    private static IServiceProvider BuildServices()
    {
        var services = new ServiceCollection();
        var logDir = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DemoTape", "logs");
        services.AddLogging(b =>
        {
            b.SetMinimumLevel(LogLevel.Information);
            b.AddProvider(new FileLoggerProvider(logDir));
        });
        services.AddDemoTape();
        return services.BuildServiceProvider();
    }

    private void CreateTrayIcon(ShellViewModel shell)
    {
        var menu = new MenuFlyout();

        var startStop = new MenuFlyoutItem { Text = shell.StatusText, Command = shell.ToggleRecordingCommand };
        shell.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(ShellViewModel.StatusText)) return;
            startStop.Text = shell.StatusText;
            // Reflect recording/rendering state in the tray tooltip so it's evident work is happening.
            try
            {
                if (_trayIcon is not null)
                    _trayIcon.ToolTipText = shell.State switch
                    {
                        RecordingState.Recording => "DemoTape — Recording…",
                        RecordingState.Rendering => "DemoTape — Rendering…",
                        RecordingState.Countdown => "DemoTape — Get ready…",
                        _ => "DemoTape",
                    };
            }
            catch { /* tooltip is cosmetic */ }
        };
        menu.Items.Add(startStop);
        menu.Items.Add(new MenuFlyoutSeparator());

        // Recording Options submenu: capture mode as a radio group. Commands are wired directly
        // (reliable in the tray flyout); the checked state is re-synced from the actual setting
        // each time the menu opens.
        var fullScreen = new RadioMenuFlyoutItem { Text = "Full Screen", GroupName = "captureMode", IsChecked = !shell.UseRegion, Command = shell.SelectFullScreenCommand };
        var selectArea = new RadioMenuFlyoutItem { Text = "Select Recording Area…", GroupName = "captureMode", IsChecked = shell.UseRegion, Command = shell.SelectRecordingAreaCommand };
        var recordingOptions = new MenuFlyoutSubItem { Text = "Recording Options" };
        recordingOptions.Items.Add(fullScreen);
        recordingOptions.Items.Add(selectArea);
        menu.Items.Add(recordingOptions);
        menu.Items.Add(new MenuFlyoutSeparator());

        // Capture Options submenu (Notion-style), with real Fluent checkmarks for the toggles.
        var capture = new MenuFlyoutSubItem { Text = "Capture Options" };
        var micToggle = MakeToggleItem("Record Microphone", () => shell.CaptureMicrophone, v => shell.CaptureMicrophone = v);
        var camToggle = MakeToggleItem("Record Webcam", () => shell.CaptureWebcam, v => shell.CaptureWebcam = v);
        capture.Items.Add(micToggle);
        capture.Items.Add(camToggle);
        capture.Items.Add(new MenuFlyoutSeparator());
        // On-device audio cleanup (applied to the mic before muxing).
        var noiseToggle = MakeToggleItem("Smart Noise Suppression", () => shell.NoiseSuppression, v => shell.NoiseSuppression = v);
        var enhanceToggle = MakeToggleItem("Enhance Voice", () => shell.EnhanceVoice, v => shell.EnhanceVoice = v);
        capture.Items.Add(noiseToggle);
        capture.Items.Add(enhanceToggle);

        // Keep the whole menu's checkable state in sync with the persisted settings whenever it
        // opens (the region selector, for instance, flips UseRegion in settings directly).
        menu.Opening += (_, _) =>
        {
            shell.RefreshFromSettings();
            fullScreen.IsChecked = !shell.UseRegion;
            selectArea.IsChecked = shell.UseRegion;
            micToggle.IsChecked = shell.CaptureMicrophone;
            camToggle.IsChecked = shell.CaptureWebcam;
            noiseToggle.IsChecked = shell.NoiseSuppression;
            enhanceToggle.IsChecked = shell.EnhanceVoice;
        };

        capture.Items.Add(new MenuFlyoutSeparator());
        capture.Items.Add(new MenuFlyoutItem { Text = "Webcam Settings…", Command = shell.OpenWebcamSettingsCommand });
        capture.Items.Add(new MenuFlyoutItem { Text = "Background…", Command = shell.OpenBackgroundPickerCommand });
        menu.Items.Add(capture);
        menu.Items.Add(new MenuFlyoutSeparator());

        // After Recording — post-processing actions (each opens a focused two-pane window).
        menu.Items.Add(new MenuFlyoutItem { Text = "Auto-Cut & Speed Up Latest…", Command = shell.AutoCutCommand });

        var aiFeatures = new MenuFlyoutSubItem { Text = "AI Features" };
        aiFeatures.Items.Add(new MenuFlyoutItem { Text = "AI Settings…", Command = shell.OpenAiSettingsCommand });
        aiFeatures.Items.Add(new MenuFlyoutSeparator());
        aiFeatures.Items.Add(new MenuFlyoutItem { Text = "Generate Captions for Latest…", Command = shell.GenerateCaptionsCommand });
        aiFeatures.Items.Add(new MenuFlyoutItem { Text = "Generate Voiceover for Latest…", Command = shell.GenerateVoiceoverCommand });
        aiFeatures.Items.Add(new MenuFlyoutItem { Text = "Generate Avatar Presenter for Latest…", Command = shell.GenerateAvatarCommand });
        menu.Items.Add(aiFeatures);

        menu.Items.Add(new MenuFlyoutItem { Text = "Web Publish Latest…", Command = shell.OpenWebPublishCommand });
        menu.Items.Add(new MenuFlyoutItem { Text = "Open Recordings Folder", Command = shell.OpenRecordingsFolderCommand });
        menu.Items.Add(new MenuFlyoutSeparator());

        // System Preferences submenu (checkable toggles, like the macOS app).
        var sysPrefs = new MenuFlyoutSubItem { Text = "System Preferences" };
        var loginToggle = MakeToggleItem("Open at Login",
            () => Infrastructure.StartupRegistration.IsEnabled,
            v => Infrastructure.StartupRegistration.SetEnabled(v));
        var autoZoomToggle = MakeToggleItem("Auto-Zoom", () => shell.AutoZoom, v => shell.AutoZoom = v);
        sysPrefs.Items.Add(loginToggle);
        sysPrefs.Items.Add(autoZoomToggle);
        menu.Items.Add(sysPrefs);
        menu.Opening += (_, _) =>
        {
            loginToggle.IsChecked = Infrastructure.StartupRegistration.IsEnabled;
            autoZoomToggle.IsChecked = shell.AutoZoom;
        };

        menu.Items.Add(new MenuFlyoutItem { Text = "About DemoTape", Command = shell.OpenAboutCommand });
        menu.Items.Add(new MenuFlyoutSeparator());

        // Use Command, not Click: Click events don't fire inside the H.NotifyIcon tray flyout.
        var quit = new MenuFlyoutItem { Text = "Quit DemoTape", Command = new RelayCommand(Quit) };
        menu.Items.Add(quit);

        _trayIcon = new TaskbarIcon
        {
            ToolTipText = "DemoTape",
            ContextFlyout = menu,
        };
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "demotape.ico");
        if (!File.Exists(iconPath))
            iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "trayicon.png");
        if (File.Exists(iconPath))
            _trayIcon.IconSource = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(iconPath));
        // No left-click action: the menu opens on right-click (standard tray behavior). Left-click
        // must NOT open a settings window.
        _trayIcon.ForceCreate();
    }

    // A real Fluent checkable item. Driven by Command (which fires reliably in the tray flyout,
    // unlike Click); we set IsChecked explicitly so the native checkmark always matches the state.
    private static ToggleMenuFlyoutItem MakeToggleItem(string text, Func<bool> get, Action<bool> set)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = get() };
        item.Command = new RelayCommand(() =>
        {
            bool newValue = !get();
            set(newValue);
            item.IsChecked = newValue;
        });
        return item;
    }

    private void RegisterHotKey(ShellViewModel shell)
    {
        _hotKey = new GlobalHotKey(GlobalHotKey.Modifiers.Control | GlobalHotKey.Modifiers.Shift, 0x52 /* R */);
        _hotKey.Pressed += () => _ = shell.ToggleRecordingCommand.ExecuteAsync(null);
        _hotKey.Register();
    }

    private void Quit()
    {
        try
        {
            _hotKey?.Dispose();
            _trayIcon?.Dispose();
            _hostWindow?.Close();
        }
        catch { /* ignore */ }
        Exit();
        // Hard-exit as a fallback: the hidden host window + tray can otherwise keep the process alive.
        Environment.Exit(0);
    }
}
