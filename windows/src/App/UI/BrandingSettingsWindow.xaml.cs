using System;
using System.IO;
using DemoTape.Domain.Abstractions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>Configures the branding watermark baked into the styled output.</summary>
public sealed partial class BrandingSettingsWindow : Window
{
    private readonly ISettingsStore _settings;
    private string _imagePath = "";

    public BrandingSettingsWindow(ISettingsStore settings)
    {
        _settings = settings;
        InitializeComponent();
        WindowIcon.Apply(this);
        Title = "Branding";

        var s = settings.Load();
        EnableBox.IsChecked = s.BrandingEnabled;
        _imagePath = s.BrandingImagePath;
        PositionCombo.SelectedItem = s.BrandingPosition;
        if (PositionCombo.SelectedItem is null) PositionCombo.SelectedIndex = 3;
        OpacitySlider.Value = Math.Clamp(s.BrandingOpacity * 100, 10, 100);
        ScaleSlider.Value = Math.Clamp(s.BrandingScale * 100, 4, 40);
        ShowImage(_imagePath);
    }

    private void ShowImage(string path)
    {
        if (File.Exists(path)) { Preview.Source = new BitmapImage(new Uri(path)); PathLabel.Text = Path.GetFileName(path); }
        else { Preview.Source = null; PathLabel.Text = "No image chosen"; }
    }

    private async void OnChooseImage(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".png"); picker.FileTypeFilter.Add(".jpg"); picker.FileTypeFilter.Add(".jpeg");
        var file = await picker.PickSingleFileAsync();
        if (file is not null) { _imagePath = file.Path; ShowImage(_imagePath); }
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var s = _settings.Load();
        s.BrandingEnabled = EnableBox.IsChecked == true;
        s.BrandingImagePath = _imagePath;
        s.BrandingPosition = PositionCombo.SelectedItem as string ?? "BottomRight";
        s.BrandingOpacity = OpacitySlider.Value / 100.0;
        s.BrandingScale = ScaleSlider.Value / 100.0;
        _settings.Save(s);
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();
}
