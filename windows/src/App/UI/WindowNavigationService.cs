using DemoTape.App.Infrastructure;
using DemoTape.Domain;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Ai;
using DemoTape.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace DemoTape.App.UI;

/// <summary>
/// Opens the app's secondary windows (Web Publish, region selector, background picker, webcam
/// settings).
/// </summary>
public sealed class WindowNavigationService : INavigationService
{
    private readonly IServiceProvider _services;
    private readonly WindowsUserInteraction _interaction;
    private readonly ISettingsStore _settingsStore;
    private WebPublishWindow? _webPublish;
    private BackgroundPickerWindow? _backgroundPicker;
    private WebcamSettingsWindow? _webcamSettings;
    private AISettingsWindow? _aiSettings;
    private ActionPreviewWindow? _actionPreview;
    private AboutWindow? _about;

    public WindowNavigationService(IServiceProvider services, WindowsUserInteraction interaction, ISettingsStore settingsStore)
    {
        _services = services;
        _interaction = interaction;
        _settingsStore = settingsStore;
    }

    public void OpenWebPublish()
    {
        if (_webPublish is not null)
        {
            _webPublish.Activate();
            return;
        }
        var vm = _services.GetRequiredService<WebPublishViewModel>();
        _webPublish = new WebPublishWindow(vm, _interaction);
        _webPublish.Closed += (_, _) => _webPublish = null;
        _webPublish.Activate();
    }

    public void OpenBackgroundPicker()
    {
        if (_backgroundPicker is not null) { _backgroundPicker.Activate(); return; }
        _backgroundPicker = new BackgroundPickerWindow(_settingsStore);
        _backgroundPicker.Closed += (_, _) => _backgroundPicker = null;
        _backgroundPicker.Activate();
    }

    public void OpenWebcamSettings()
    {
        if (_webcamSettings is not null) { _webcamSettings.Activate(); return; }
        _webcamSettings = new WebcamSettingsWindow(_settingsStore);
        _webcamSettings.Closed += (_, _) => _webcamSettings = null;
        _webcamSettings.Activate();
    }

    public void OpenAbout()
    {
        if (_about is not null) { _about.Activate(); return; }
        _about = new AboutWindow();
        _about.Closed += (_, _) => _about = null;
        _about.Activate();
    }

    private BrandingSettingsWindow? _branding;
    public void OpenBrandingSettings()
    {
        if (_branding is not null) { _branding.Activate(); return; }
        _branding = new BrandingSettingsWindow(_settingsStore);
        _branding.Closed += (_, _) => _branding = null;
        _branding.Activate();
    }

    private TeleprompterSettingsWindow? _teleprompterSettings;
    public void OpenTeleprompterSettings()
    {
        if (_teleprompterSettings is not null) { _teleprompterSettings.Activate(); return; }
        _teleprompterSettings = new TeleprompterSettingsWindow(_settingsStore);
        _teleprompterSettings.Closed += (_, _) => _teleprompterSettings = null;
        _teleprompterSettings.Activate();
    }

    public async void ChangeOutputDirectory()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, _interaction.WindowHandle);
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        var s = _settingsStore.Load();
        s.OutputDirectoryOverride = folder.Path;
        _settingsStore.Save(s);
        _interaction.Notify("Output folder changed", folder.Path);
    }

    public void OpenAiSettings()
    {
        if (_aiSettings is not null) { _aiSettings.Activate(); return; }
        _aiSettings = new AISettingsWindow(_settingsStore,
            _services.GetRequiredService<IKeyStore>(),
            _services.GetRequiredService<KeyTester>());
        _aiSettings.Closed += (_, _) => _aiSettings = null;
        _aiSettings.Activate();
    }

    public void GenerateCaptions()
    {
        var s = _settingsStore.Load();
        var keys = _services.GetRequiredService<IKeyStore>();
        if (!s.CaptionsEnabled || !keys.Exists(KeyAccounts.Stt))
        {
            PromptEnable("Captions", "Enable captions and add a transcription API key in AI Settings first.");
            return;
        }
        var latest = LatestOrPrompt();
        if (latest is null || !ShowSingleAction()) return;
        var action = new CaptionsAction(_settingsStore, keys,
            _services.GetRequiredService<ITranscriptionProvider>(),
            _services.GetRequiredService<CaptionBurner>(), _interaction);
        Present(action.Create(latest));
    }

    public void GenerateVoiceover()
    {
        var s = _settingsStore.Load();
        var keys = _services.GetRequiredService<IKeyStore>();
        if (!s.VoiceoverEnabled || !keys.Exists(KeyAccounts.ElevenLabs))
        {
            PromptEnable("Voiceover", "Enable voiceover and add an ElevenLabs API key in AI Settings first.");
            return;
        }
        var latest = LatestOrPrompt();
        if (latest is null || !ShowSingleAction()) return;
        var action = new VoiceoverAction(_settingsStore, keys,
            _services.GetRequiredService<IVoiceProvider>(), _interaction);
        Present(action.Create(latest));
    }

    public void GenerateAvatar()
    {
        var keys = _services.GetRequiredService<IKeyStore>();
        if (!keys.Exists(KeyAccounts.HeyGen))
        {
            PromptEnable("Avatar Presenter", "Add a HeyGen API key in AI Settings to generate an avatar presenter.");
            return;
        }
        var latest = LatestOrPrompt();
        if (latest is null || !ShowSingleAction()) return;
        var action = new AvatarAction(_settingsStore, keys,
            _services.GetRequiredService<IAvatarProvider>(),
            _services.GetRequiredService<AvatarCompositor>(), _interaction);
        Present(action.Create(latest));
    }

    public void AutoCut()
    {
        var latest = LatestOrPrompt();
        if (latest is null || !ShowSingleAction()) return;
        var service = new Infrastructure.AutoCutService();

        // ----- Finer speed controls (feature: SpeedSlider) -----
        // Default 1.25× — the "recommended" band is 0.75×–2.0×.
        double speedMultiplier = 1.25;

        var speedLabel = new TextBlock
        {
            Text = "1.3×",
            Width = 44,
            VerticalAlignment = Microsoft.UI.Xaml.VerticalAlignment.Center,
            FontWeight = FontWeights.SemiBold,
        };
        var slider = new Slider
        {
            Minimum = 0.5,
            Maximum = 3.0,
            StepFrequency = 0.1,
            SnapsTo = SliderSnapsTo.StepValues,
            Value = speedMultiplier,
            Width = 180,
            VerticalAlignment = Microsoft.UI.Xaml.VerticalAlignment.Center,
        };
        var decBtn = new Button { Content = "−", Padding = new Microsoft.UI.Xaml.Thickness(10, 4, 10, 4) };
        var incBtn = new Button { Content = "+", Padding = new Microsoft.UI.Xaml.Thickness(10, 4, 10, 4) };

        void UpdateSpeed(double v)
        {
            speedMultiplier = Math.Round(Math.Clamp(v, 0.5, 3.0), 1);
            slider.Value = speedMultiplier;
            speedLabel.Text = $"{speedMultiplier:0.0}×";
        }

        slider.ValueChanged += (_, e) => UpdateSpeed(e.NewValue);
        decBtn.Click += (_, _) => UpdateSpeed(speedMultiplier - 0.1);
        incBtn.Click += (_, _) => UpdateSpeed(speedMultiplier + 0.1);
        UpdateSpeed(speedMultiplier);

        var speedRow = new StackPanel
        {
            Orientation = Microsoft.UI.Xaml.Controls.Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = Microsoft.UI.Xaml.VerticalAlignment.Center,
        };
        speedRow.Children.Add(decBtn);
        speedRow.Children.Add(slider);
        speedRow.Children.Add(incBtn);
        speedRow.Children.Add(speedLabel);

        var controls = new StackPanel { Spacing = 4 };
        controls.Children.Add(new TextBlock { Text = "Speed", FontWeight = FontWeights.SemiBold, FontSize = 12 });
        controls.Children.Add(speedRow);
        controls.Children.Add(new TextBlock
        {
            Text = "Recommended range: 0.75× – 2.0×",
            FontSize = 11,
            Opacity = 0.6,
        });

        ActionPreviewWindow.RenderDelegate render = async (src, progress, ct) =>
        {
            var outPath = Domain.Ai.VoiceoverPlanner.CaptionedPath(src).Replace(".captioned.mp4", ".tight.mp4");
            var opts = new Infrastructure.AutoCutService.Options(SpeedMultiplier: speedMultiplier);
            return await service.AutoCutAsync(src, outPath, opts, progress, ct);
        };
        Present(new ActionPreviewWindow("Auto-Cut & Speed Up", latest, controls, render, _interaction,
            "Nothing to trim — no long silent gaps were found."));
    }

    private string? LatestOrPrompt()
    {
        // Source chaining: prefer the highest-priority derivative (captioned > tight > voiceover >
        // avatar > styled > raw) so actions always open on the best available version.
        var paths = _services.GetRequiredService<IPathService>();
        var best = RecordingLayout.LatestSource(paths.OutputDirectory);
        if (best is not null) return best;
        _ = _interaction.ShowMessageAsync("No recording yet",
            "Record something first — post-recording actions run on your latest recording.");
        return null;
    }

    private bool ShowSingleAction()
    {
        if (_actionPreview is null) return true;
        _actionPreview.Activate();
        return false;
    }

    private void Present(ActionPreviewWindow window)
    {
        _actionPreview = window;
        _actionPreview.Closed += (_, _) => _actionPreview = null;
        _actionPreview.Activate();
    }

    private void PromptEnable(string feature, string message)
    {
        _ = _interaction.ShowMessageAsync($"{feature} needs a key", message);
        OpenAiSettings();
    }
}
