using System.Runtime.InteropServices;
using DemoTape.Domain.Abstractions;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.System;
using Windows.UI;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>
/// Full-screen overlay for positioning the webcam circle — live preview, drag to move, corner
/// handle to resize, and an in-circle zoom slider. Mirrors the macOS WebcamSettingsController.
/// Save persists position, size, and zoom to settings.
/// </summary>
public sealed partial class WebcamSettingsWindow : Window
{
    private enum Mode { None, Move, Resize }

    private readonly ISettingsStore _settingsStore;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _dispatcher =
        Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private readonly SoftwareBitmapSource _preview = new();

    private MediaCapture? _capture;
    private MediaFrameReader? _reader;
    private volatile bool _updating;

    private Mode _mode;
    private Point _pointerStart;
    private Point _puckStart;
    private double _minD, _maxD;

    public WebcamSettingsWindow(ISettingsStore settingsStore)
    {
        _settingsStore = settingsStore;
        InitializeComponent();

        var hwnd = WindowNative.GetWindowHandle(this);
        MakeFullScreenOverlay(hwnd);

        CamBrush.ImageSource = _preview;
        Root.Loaded += OnLoaded;
        Root.KeyDown += (_, e) => { if (e.Key == VirtualKey.Escape) Close(); };
        Puck.PointerPressed += OnPointerPressed;
        Puck.PointerMoved += OnPointerMoved;
        Puck.PointerReleased += OnPointerReleased;
        ZoomSlider.ValueChanged += (_, _) => ApplyZoom();
        Closed += (_, _) => StopPreview();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        var s = _settingsStore.Load();
        double sw = Root.ActualWidth, sh = Root.ActualHeight;
        _minD = 0.10 * sw;
        _maxD = 0.40 * sw;

        double d = Math.Clamp(s.WebcamSize * sw, _minD, _maxD);
        SetDiameter(d);
        double cx = s.WebcamPositionX * sw, cy = s.WebcamPositionY * sh;
        Canvas.SetLeft(Puck, cx - d / 2);
        Canvas.SetTop(Puck, cy - d / 2);
        ZoomSlider.Value = Math.Clamp(s.WebcamZoom, 1, 3);
        ApplyZoom();

        Root.Focus(FocusState.Programmatic);
        _ = StartPreviewAsync();
    }

    // ---- Live preview via MediaFrameReader (graceful if unavailable) ----

    private async Task StartPreviewAsync()
    {
        try
        {
            _capture = new MediaCapture();
            await _capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                StreamingCaptureMode = StreamingCaptureMode.Video,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu,
                SharingMode = MediaCaptureSharingMode.ExclusiveControl,
            });

            var source = _capture.FrameSources.Values.FirstOrDefault(
                f => f.Info.SourceKind == MediaFrameSourceKind.Color) ?? _capture.FrameSources.Values.FirstOrDefault();
            if (source is null) { ShowPlaceholder(); return; }

            _reader = await _capture.CreateFrameReaderAsync(source);
            _reader.FrameArrived += OnFrameArrived;
            await _reader.StartAsync();
        }
        catch
        {
            ShowPlaceholder();
        }
    }

    private void OnFrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        if (_updating) return;
        using var frame = sender.TryAcquireLatestFrame();
        var bmp = frame?.VideoMediaFrame?.SoftwareBitmap;
        if (bmp is null) return;

        var converted = SoftwareBitmap.Convert(bmp, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        _updating = true;
        _dispatcher.TryEnqueue(async () =>
        {
            try { await _preview.SetBitmapAsync(converted); }
            catch { }
            finally { converted.Dispose(); _updating = false; }
        });
    }

    private void ShowPlaceholder() =>
        _dispatcher.TryEnqueue(() => Circle.Fill = new SolidColorBrush(Color.FromArgb(255, 40, 44, 52)));

    private async void StopPreview()
    {
        try
        {
            if (_reader is not null) { _reader.FrameArrived -= OnFrameArrived; await _reader.StopAsync(); _reader.Dispose(); _reader = null; }
        }
        catch { }
        try { _capture?.Dispose(); } catch { }
        _capture = null;
    }

    // ---- Interaction ----

    private void ApplyZoom()
    {
        double z = ZoomSlider.Value;
        // Mirror (selfie) + zoom, centered in the brush's 0..1 space.
        CamBrush.RelativeTransform = new CompositeTransform { CenterX = 0.5, CenterY = 0.5, ScaleX = -z, ScaleY = z };
    }

    private void SetDiameter(double d)
    {
        Puck.Width = d; Puck.Height = d;
        Circle.Width = d; Circle.Height = d;
        foreach (var el in Puck.Children.OfType<Microsoft.UI.Xaml.Shapes.Ellipse>())
        {
            el.Width = d; el.Height = d;
        }
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(Layer).Position;
        if (IsWithin(e.OriginalSource as DependencyObject, Handle)) _mode = Mode.Resize;
        else if (IsWithin(e.OriginalSource as DependencyObject, ZoomSlider)) return; // let the slider handle it
        else _mode = Mode.Move;

        _pointerStart = p;
        _puckStart = new Point(Canvas.GetLeft(Puck), Canvas.GetTop(Puck));
        Puck.CapturePointer(e.Pointer);
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_mode == Mode.None) return;
        var p = e.GetCurrentPoint(Layer).Position;

        if (_mode == Mode.Move)
        {
            double left = _puckStart.X + (p.X - _pointerStart.X);
            double top = _puckStart.Y + (p.Y - _pointerStart.Y);
            left = Math.Clamp(left, 0, Math.Max(0, Root.ActualWidth - Puck.Width));
            top = Math.Clamp(top, 0, Math.Max(0, Root.ActualHeight - Puck.Height));
            Canvas.SetLeft(Puck, left);
            Canvas.SetTop(Puck, top);
        }
        else // Resize: new radius = distance from center to pointer
        {
            double cx = Canvas.GetLeft(Puck) + Puck.Width / 2;
            double cy = Canvas.GetTop(Puck) + Puck.Height / 2;
            double r = Math.Sqrt((p.X - cx) * (p.X - cx) + (p.Y - cy) * (p.Y - cy));
            double d = Math.Clamp(r * 2, _minD, _maxD);
            SetDiameter(d);
            Canvas.SetLeft(Puck, cx - d / 2);
            Canvas.SetTop(Puck, cy - d / 2);
        }
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        Puck.ReleasePointerCapture(e.Pointer);
        _mode = Mode.None;
    }

    private static bool IsWithin(DependencyObject? node, DependencyObject ancestor)
    {
        while (node is not null)
        {
            if (ReferenceEquals(node, ancestor)) return true;
            node = VisualTreeHelper.GetParent(node);
        }
        return false;
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        double sw = Root.ActualWidth, sh = Root.ActualHeight;
        if (sw > 0 && sh > 0)
        {
            double cx = Canvas.GetLeft(Puck) + Puck.Width / 2;
            double cy = Canvas.GetTop(Puck) + Puck.Height / 2;
            var s = _settingsStore.Load();
            s.WebcamPositionX = Math.Clamp(cx / sw, 0, 1);
            s.WebcamPositionY = Math.Clamp(cy / sh, 0, 1);
            s.WebcamSize = Math.Clamp(Puck.Width / sw, 0.05, 0.5);
            s.WebcamZoom = ZoomSlider.Value;
            _settingsStore.Save(s);
        }
        Close();
    }

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
