using System;
using System.IO;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>
/// First-run welcome, shown the first few launches then about monthly (see
/// <c>WelcomeSchedule</c>). Leads with what DemoTape does, and — unlike macOS, where Screen
/// Recording is a hard permission gate — notes that Windows capture just works and only mic/camera
/// are prompted on use. Everything stays reachable later from the tray menu.
/// </summary>
public sealed partial class WelcomeWindow : Window
{
    public WelcomeWindow()
    {
        InitializeComponent();
        WindowIcon.Apply(this);
        Title = "Welcome to DemoTape";

        var ico = Path.Combine(AppContext.BaseDirectory, "Assets", "trayicon.png");
        if (File.Exists(ico)) LogoImage.Source = new BitmapImage(new Uri(ico));

        ConfigureWindow();
    }

    private void ConfigureWindow()
    {
        var hwnd = WindowNative.GetWindowHandle(this);
        var id = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = AppWindow.GetFromWindowId(id);

        if (appWindow.Presenter is OverlappedPresenter p)
        {
            p.IsResizable = false;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
        }

        const int w = 640, h = 440;
        appWindow.Resize(new SizeInt32(w, h));
        var area = DisplayArea.GetFromWindowId(id, DisplayAreaFallback.Primary);
        var wa = area.WorkArea;
        appWindow.Move(new PointInt32(wa.X + (wa.Width - w) / 2, wa.Y + (wa.Height - h) / 2));
    }

    private void OnStart(object sender, RoutedEventArgs e) => Close();
}
