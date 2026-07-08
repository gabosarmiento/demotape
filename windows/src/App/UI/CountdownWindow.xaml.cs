using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>
/// Full-screen, click-through "3-2-1" countdown overlay shown before capture begins, so it never
/// appears in the recording. The Windows analogue of the macOS <c>CountdownController</c>.
/// </summary>
public sealed partial class CountdownWindow : Window
{
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();

    public CountdownWindow()
    {
        InitializeComponent();
        var hwnd = WindowNative.GetWindowHandle(this);
        MakeBorderlessTopmostClickThrough(hwnd);
    }

    /// <summary>Counts down from <paramref name="seconds"/>, then invokes <paramref name="onComplete"/> and closes.</summary>
    public async Task RunAsync(int seconds, Func<Task> onComplete)
    {
        Activate();
        for (int n = seconds; n >= 1; n--)
        {
            NumberText.Text = n.ToString();
            await Task.Delay(1000);
        }
        this.Close();
        await onComplete();
    }

    private static void MakeBorderlessTopmostClickThrough(IntPtr hwnd)
    {
        // Cover the primary work area, borderless, always-on-top, transparent to input.
        var ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW);
        SetWindowLong(hwnd, GWL_STYLE, WS_POPUP | WS_VISIBLE);

        int w = GetSystemMetrics(SM_CXSCREEN);
        int h = GetSystemMetrics(SM_CYSCREEN);
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
    }

    private const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    private const int WS_POPUP = unchecked((int)0x80000000), WS_VISIBLE = 0x10000000;
    private const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80;
    private const int SM_CXSCREEN = 0, SM_CYSCREEN = 1;
    private const uint SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040, LWA_ALPHA = 0x2;
    private static readonly IntPtr HWND_TOPMOST = new(-1);

    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint crKey, byte alpha, uint flags);
}
