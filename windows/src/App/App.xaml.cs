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

    public App() => InitializeComponent();

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

        CreateTrayIcon(_shell);
        RegisterHotKey(_shell);
    }

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

        menu.Items.Add(MakeToggle("Record Microphone", shell.CaptureMicrophone, v => shell.CaptureMicrophone = v));
        menu.Items.Add(MakeToggle("Show Webcam", shell.CaptureWebcam, v => shell.CaptureWebcam = v));
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
        _trayIcon.LeftClickCommand = shell.OpenWebPublishCommand;
        _trayIcon.ForceCreate();
    }

    private static ToggleMenuFlyoutItem MakeToggle(string text, bool initial, Action<bool> onChanged)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = initial };
        item.Click += (_, _) => onChanged(item.IsChecked);
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
        _hotKey?.Dispose();
        _trayIcon?.Dispose();
        Exit();
    }
}
