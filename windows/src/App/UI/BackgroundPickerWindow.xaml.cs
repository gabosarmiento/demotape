using DemoTape.Domain.Abstractions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using WinUIVisibility = Microsoft.UI.Xaml.Visibility;
using Windows.Graphics;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>A background tile: a bundled/custom image, or the "add custom" slot.</summary>
public sealed class BackgroundItem
{
    public string FileName { get; set; } = "";   // bundled asset name, or absolute path for custom
    public BitmapImage? Image { get; set; }
    public bool IsCustom { get; set; }
    /// <summary>Show the "＋ Custom Image" placeholder when this is the custom slot with no image yet.</summary>
    public WinUIVisibility AddOverlayVisibility =>
        IsCustom && Image is null ? WinUIVisibility.Visible : WinUIVisibility.Collapsed;
}

/// <summary>
/// Gallery for choosing the framed-mode background — bundled gradients plus a custom-image tile.
/// Pick a tile (it stays highlighted), then Confirm to apply. Mirrors the macOS BackgroundPicker.
/// </summary>
public sealed partial class BackgroundPickerWindow : Window
{
    private readonly ISettingsStore _settingsStore;
    private readonly List<BackgroundItem> _items = new();

    public BackgroundPickerWindow(ISettingsStore settingsStore)
    {
        _settingsStore = settingsStore;
        InitializeComponent();
        Title = "DemoTape — Choose Background";
        AppWindow.Resize(new SizeInt32(820, 620));
        LoadGallery();
    }

    private void LoadGallery()
    {
        _items.Clear();
        var current = _settingsStore.Load().BackgroundFile;

        var dir = Path.Combine(AppContext.BaseDirectory, "Assets", "Backgrounds");
        if (Directory.Exists(dir))
        {
            foreach (var p in Directory.EnumerateFiles(dir, "*.png").OrderBy(Path.GetFileName))
            {
                _items.Add(new BackgroundItem
                {
                    FileName = Path.GetFileName(p),
                    Image = new BitmapImage(new Uri(p)) { DecodePixelWidth = 368 },
                });
            }
        }

        // Custom slot as the last tile. If the current selection is a custom absolute path, preload it.
        var customItem = new BackgroundItem { IsCustom = true };
        if (Path.IsPathRooted(current) && File.Exists(current))
        {
            customItem.FileName = current;
            customItem.Image = new BitmapImage(new Uri(current)) { DecodePixelWidth = 368 };
        }
        _items.Add(customItem);

        Gallery.ItemsSource = _items;

        // Pre-select the current background so it stays highlighted on reopen.
        var selected = _items.FirstOrDefault(i =>
            (!i.IsCustom && i.FileName == current) || (i.IsCustom && i.FileName == current));
        Gallery.SelectedItem = selected ?? _items.FirstOrDefault();
    }

    private async void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not BackgroundItem item) return;
        Gallery.SelectedItem = item;
        if (item.IsCustom) await PickCustomAsync(item);
    }

    private async Task PickCustomAsync(BackgroundItem item)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        picker.FileTypeFilter.Add(".png");
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;

        item.FileName = file.Path;
        item.Image = new BitmapImage(new Uri(file.Path)) { DecodePixelWidth = 368 };
        // Rebuild so the tile shows the chosen image (and stays selected).
        Gallery.ItemsSource = null;
        Gallery.ItemsSource = _items;
        Gallery.SelectedItem = item;
    }

    private void OnConfirm(object sender, RoutedEventArgs e)
    {
        if (Gallery.SelectedItem is BackgroundItem item && !string.IsNullOrEmpty(item.FileName))
        {
            var s = _settingsStore.Load();
            s.BackgroundFile = item.FileName;
            _settingsStore.Save(s);
        }
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();
}
