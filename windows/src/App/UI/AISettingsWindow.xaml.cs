using System;
using System.Linq;
using DemoTape.App.Infrastructure;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Ai;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace DemoTape.App.UI;

/// <summary>
/// Settings for the opt-in, bring-your-own-key AI features (Captions, Voiceover, Avatar). Keys are
/// validated with a live "Test key" call and stored in Windows Credential Manager via
/// <see cref="IKeyStore"/>. The Windows analogue of the macOS AISettingsController.
/// </summary>
public sealed partial class AISettingsWindow : Window
{
    private readonly ISettingsStore _settingsStore;
    private readonly IKeyStore _keys;
    private readonly KeyTester _tester;

    public AISettingsWindow(ISettingsStore settingsStore, IKeyStore keys, KeyTester tester)
    {
        _settingsStore = settingsStore;
        _keys = keys;
        _tester = tester;
        InitializeComponent();
        WindowIcon.Apply(this);

        Title = "AI Features";
        var s = _settingsStore.Load();

        foreach (var p in AiCatalog.SttProviders) ProviderCombo.Items.Add(p.Name);
        ProviderCombo.SelectedItem = AiCatalog.SttProviders.Any(p => p.Name == s.AiProvider) ? s.AiProvider : "OpenAI";
        ProviderCombo.SelectionChanged += (_, _) => ApplyProviderPreset();

        SttBase.Text = s.SttBaseUrl;
        SttModel.Text = s.SttModel;
        SttLang.Text = s.SttLanguage;
        CaptionsEnable.IsChecked = s.CaptionsEnabled;
        VoiceoverEnable.IsChecked = s.VoiceoverEnabled;

        MarkStored(KeyAccounts.Stt, SttRemove);
        MarkStored(KeyAccounts.ElevenLabs, ElevenRemove);
        MarkStored(KeyAccounts.HeyGen, HeyGenRemove);
    }

    private void MarkStored(string account, Button removeButton)
        => removeButton.Visibility = _keys.Exists(account) ? Visibility.Visible : Visibility.Collapsed;

    private void ApplyProviderPreset()
    {
        var name = ProviderCombo.SelectedItem as string;
        var p = AiCatalog.SttProviders.FirstOrDefault(x => x.Name == name);
        if (p is null || p.Name == "Custom") { SttKeyLink.Visibility = Visibility.Collapsed; return; }
        SttBase.Text = p.BaseUrl;
        SttModel.Text = p.Model;
        SttKeyLink.Visibility = string.IsNullOrEmpty(p.KeysUrl) ? Visibility.Collapsed : Visibility.Visible;
    }

    // ---- Test buttons ----

    private async void OnTestStt(object sender, RoutedEventArgs e)
    {
        SttResult.Text = "Testing…";
        var typed = SttKey.Password.Trim();
        var key = typed.Length > 0 ? typed : _keys.Get(KeyAccounts.Stt) ?? "";
        var r = await _tester.TestSttAsync(SttBase.Text.Trim(), key);
        Show(SttResult, r);
        if (r.Kind == KeyTestKind.Ok && typed.Length > 0) { _keys.Set(KeyAccounts.Stt, typed); MarkStored(KeyAccounts.Stt, SttRemove); CaptionsEnable.IsChecked = true; }
    }

    private async void OnTestEleven(object sender, RoutedEventArgs e)
    {
        ElevenResult.Text = "Testing…";
        var typed = ElevenKey.Password.Trim();
        var key = typed.Length > 0 ? typed : _keys.Get(KeyAccounts.ElevenLabs) ?? "";
        var r = await _tester.TestElevenLabsAsync(key);
        Show(ElevenResult, r);
        if (r.Kind == KeyTestKind.Ok && typed.Length > 0) { _keys.Set(KeyAccounts.ElevenLabs, typed); MarkStored(KeyAccounts.ElevenLabs, ElevenRemove); VoiceoverEnable.IsChecked = true; }
    }

    private async void OnTestHeyGen(object sender, RoutedEventArgs e)
    {
        HeyGenResult.Text = "Testing…";
        var typed = HeyGenKey.Password.Trim();
        var key = typed.Length > 0 ? typed : _keys.Get(KeyAccounts.HeyGen) ?? "";
        var r = await _tester.TestHeyGenAsync(key);
        Show(HeyGenResult, r);
        if (r.Kind == KeyTestKind.Ok && typed.Length > 0) { _keys.Set(KeyAccounts.HeyGen, typed); MarkStored(KeyAccounts.HeyGen, HeyGenRemove); }
    }

    private static void Show(TextBlock label, KeyTestResult r)
    {
        var mark = r.Kind switch { KeyTestKind.Ok => "✓ ", KeyTestKind.Invalid => "✗ ", _ => "⚠ " };
        label.Text = mark + r.Message;
    }

    // ---- Remove buttons ----

    private void OnRemoveStt(object sender, RoutedEventArgs e) { _keys.Remove(KeyAccounts.Stt); SttKey.Password = ""; SttResult.Text = "Captions key removed."; SttRemove.Visibility = Visibility.Collapsed; CaptionsEnable.IsChecked = false; }
    private void OnRemoveEleven(object sender, RoutedEventArgs e) { _keys.Remove(KeyAccounts.ElevenLabs); ElevenKey.Password = ""; ElevenResult.Text = "Voiceover key removed."; ElevenRemove.Visibility = Visibility.Collapsed; VoiceoverEnable.IsChecked = false; }
    private void OnRemoveHeyGen(object sender, RoutedEventArgs e) { _keys.Remove(KeyAccounts.HeyGen); HeyGenKey.Password = ""; HeyGenResult.Text = "HeyGen key removed."; HeyGenRemove.Visibility = Visibility.Collapsed; }

    // ---- Links ----

    private void OnOpenSttKeys(object sender, RoutedEventArgs e)
    {
        var p = AiCatalog.SttProviders.FirstOrDefault(x => x.Name == (ProviderCombo.SelectedItem as string));
        if (p is not null && !string.IsNullOrEmpty(p.KeysUrl)) Launch(p.KeysUrl);
    }
    private void OnOpenElevenKeys(object sender, RoutedEventArgs e) => Launch(AiCatalog.ElevenKeysUrl);
    private void OnOpenHeyGenKeys(object sender, RoutedEventArgs e) => Launch(AiCatalog.HeyGenKeysUrl);

    private static void Launch(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { /* best effort */ }
    }

    // ---- Save / cancel ----

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var s = _settingsStore.Load();
        s.AiProvider = (ProviderCombo.SelectedItem as string) ?? "OpenAI";
        s.SttBaseUrl = SttBase.Text.Trim();
        s.SttModel = SttModel.Text.Trim();
        s.SttLanguage = SttLang.Text.Trim();
        s.CaptionsEnabled = CaptionsEnable.IsChecked == true;
        s.VoiceoverEnabled = VoiceoverEnable.IsChecked == true;
        _settingsStore.Save(s);

        // A typed key replaces the stored one; blank leaves it untouched (removal is explicit).
        SaveIfTyped(SttKey, KeyAccounts.Stt);
        SaveIfTyped(ElevenKey, KeyAccounts.ElevenLabs);
        SaveIfTyped(HeyGenKey, KeyAccounts.HeyGen);
        Close();
    }

    private void SaveIfTyped(PasswordBox box, string account)
    {
        var v = box.Password.Trim();
        if (v.Length > 0) _keys.Set(account, v);
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();
}
