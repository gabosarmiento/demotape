using System;
using System.IO;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>Applies the DemoTape logo to a window's title bar / taskbar entry.</summary>
public static class WindowIcon
{
    public static void Apply(Window window)
    {
        try
        {
            var hwnd = WindowNative.GetWindowHandle(window);
            var id = Win32Interop.GetWindowIdFromWindow(hwnd);
            var appWindow = AppWindow.GetFromWindowId(id);
            var ico = Path.Combine(AppContext.BaseDirectory, "Assets", "demotape.ico");
            if (File.Exists(ico)) appWindow.SetIcon(ico);
        }
        catch { /* icon is cosmetic */ }
    }
}
