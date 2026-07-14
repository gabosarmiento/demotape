using System;
using DemoTape.Domain.Abstractions;
using Microsoft.UI.Xaml;

namespace DemoTape.App.UI;

/// <summary>Edits the teleprompter script + scroll speed/size.</summary>
public sealed partial class TeleprompterSettingsWindow : Window
{
    private readonly ISettingsStore _settings;

    public TeleprompterSettingsWindow(ISettingsStore settings)
    {
        _settings = settings;
        InitializeComponent();
        WindowIcon.Apply(this);
        Title = "Teleprompter";

        var s = settings.Load();
        EnableBox.IsChecked = s.TeleprompterEnabled;
        ScriptBox.Text = s.TeleprompterScript;
        SpeedSlider.Value = Math.Clamp(s.TeleprompterSpeed, 10, 120);
        SizeSlider.Value = Math.Clamp(s.TeleprompterFontSize, 14, 48);
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var s = _settings.Load();
        s.TeleprompterEnabled = EnableBox.IsChecked == true;
        s.TeleprompterScript = ScriptBox.Text;
        s.TeleprompterSpeed = SpeedSlider.Value;
        s.TeleprompterFontSize = SizeSlider.Value;
        _settings.Save(s);
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();
}
