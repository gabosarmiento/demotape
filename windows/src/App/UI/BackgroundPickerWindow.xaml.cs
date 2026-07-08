using DemoTape.Domain.Abstractions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>A bundled background thumbnail (file name + preview image).</summary>
public sealed class BackgroundItem
{
    public required string FileName { get; init; }
    public required string FullPath { get; init; }
    public required BitmapImage Image { get; init; }
}

/// <summary>
/// Gallery for choosing the framed-mode background — the bundled gradient wallpapers plus a custom
/// image option. The Windows analogue of the macOS <c>BackgroundPickerController</c>.
/// </summary>
public sealed partial class BackgroundPickerWindow : Window
{
    private readonly ISettingsStore _settingsStore;

    public BackgroundPickerWindow(ISettingsStore settingsStore)
    {
        _settingsStore = settingsStore;
        InitializeComponent();
        Title = "DemoTape — Choose Background";
        AppWindow.Resize(new SizeInt32(820, 560));

        LoadGallery();
        Selected.Text = _settingsStore.Load().BackgroundFile;
    }

    private void LoadGallery()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "Assets", "Backgrounds");
        if (!Directory.Exists(dir)) return;
        var items = Directory.EnumerateFiles(dir, "*.png")
            .OrderBy(p => Path.GetFileName(p))
            .Select(p => new BackgroundItem
            {
                FileName = Path.GetFileName(p),
                FullPath = p,
                Image = new BitmapImage(new Uri(p)) { DecodePixelWidth = 352 },
            })
            .ToList();
        Gallery.ItemsSource = items;
    }

    private void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not BackgroundItem item) return;
        var s = _settingsStore.Load();
        s.BackgroundFile = item.FileName; // bundled asset name
        _settingsStore.Save(s);
        Selected.Text = item.FileName;
    }

    private async void OnCustom(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        picker.FileTypeFilter.Add(".png");
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        var s = _settingsStore.Load();
        s.BackgroundFile = file.Path; // absolute path
        _settingsStore.Save(s);
        Selected.Text = file.Path;
    }
}
