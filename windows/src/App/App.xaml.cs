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
            if (e.PropertyName == nameof(ShellViewModel.StatusText))
                startStop.Text = shell.StatusText;
        };
        menu.Items.Add(startStop);
        menu.Items.Add(new MenuFlyoutSeparator());

        menu.Items.Add(new MenuFlyoutItem { Text = "Record Full Screen", Command = shell.SelectFullScreenCommand });
        menu.Items.Add(new MenuFlyoutItem { Text = "Select Recording Area…", Command = shell.SelectRecordingAreaCommand });
        menu.Items.Add(new MenuFlyoutSeparator());

        var micItem = MakeCheckItem("Record Microphone", () => shell.CaptureMicrophone, v => shell.CaptureMicrophone = v);
        var webcamItem = MakeCheckItem("Record Webcam", () => shell.CaptureWebcam, v => shell.CaptureWebcam = v);
        menu.Items.Add(micItem);
        menu.Items.Add(webcamItem);
        menu.Items.Add(new MenuFlyoutItem { Text = "Webcam Settings…", Command = shell.OpenWebcamSettingsCommand });
        menu.Items.Add(new MenuFlyoutItem { Text = "Background…", Command = shell.OpenBackgroundPickerCommand });
        menu.Items.Add(new MenuFlyoutSeparator());

        menu.Items.Add(new MenuFlyoutItem { Text = "Web Publish Latest…", Command = shell.OpenWebPublishCommand });
        menu.Items.Add(new MenuFlyoutItem { Text = "Open Recordings Folder", Command = shell.OpenRecordingsFolderCommand });
        menu.Items.Add(new MenuFlyoutSeparator());

        var quit = new MenuFlyoutItem { Text = "Quit DemoTape" };
        quit.Click += (_, _) => Quit();
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

    // A command-driven checkable item. ToggleMenuFlyoutItem's built-in toggle is unreliable in the
    // tray flyout, but Command items fire reliably — so we drive the value and the checkmark icon
    // ourselves (updated immediately in the command, visible on the next menu open).
    private static MenuFlyoutItem MakeCheckItem(string text, Func<bool> get, Action<bool> set)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = CheckIcon(get()) };
        item.Command = new RelayCommand(() =>
        {
            bool newValue = !get();
            set(newValue);
            item.Icon = CheckIcon(newValue);
        });
        return item;
    }

    private static IconElement? CheckIcon(bool on) =>
        on ? new FontIcon { Glyph = "\uE73E" } : null; // Segoe Fluent "CheckMark"

    private void RegisterHotKey(ShellViewModel shell)
    {
        _hotKey = new GlobalHotKey(GlobalHotKey.Modifiers.Control | GlobalHotKey.Modifiers.Shift, 0x52 /* R */);
        _hotKey.Pressed += () => _ = shell.ToggleRecordingCommand.ExecuteAsync(null);
        _hotKey.Register();
    }

    private void Quit()
    {
        _hotKey?.Dispose();
        _trayIcon?.Dispose();
        Exit();
    }
}
