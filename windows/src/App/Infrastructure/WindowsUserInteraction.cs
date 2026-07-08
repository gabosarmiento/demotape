using System.Diagnostics;
using System.Runtime.InteropServices;
using DemoTape.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// WinUI implementation of <see cref="IUserInteraction"/>: reveals files in Explorer and shows
/// a <see cref="ContentDialog"/>. Dialogs need a XAML root, supplied by the active window.
/// </summary>
public sealed class WindowsUserInteraction : IUserInteraction
{
    /// <summary>Set by whichever window is currently presenting, so dialogs have a XamlRoot.</summary>
    public XamlRoot? XamlRoot { get; set; }

    public void RevealInExplorer(string path)
    {
        // Selecting the folder itself: open it. Selecting a file: open its parent and select it.
        if (Directory.Exists(path))
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        else if (File.Exists(path))
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
    }

    public async Task ShowMessageAsync(string title, string message)
    {
        // Prefer a Fluent ContentDialog when a window is presenting; otherwise (tray-only
        // context) fall back to a native Win32 message box so notifications always work.
        if (XamlRoot is not null)
        {
            var dialog = new ContentDialog
            {
                Title = title,
                Content = message,
                CloseButtonText = "OK",
                XamlRoot = XamlRoot,
            };
            await dialog.ShowAsync();
            return;
        }

        MessageBox(IntPtr.Zero, message, title, 0x40 /* MB_ICONINFORMATION */);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);
}
