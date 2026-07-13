using DemoTape.App.Infrastructure;
using DemoTape.Domain.Abstractions;
using DemoTape.ViewModels;
using Microsoft.Extensions.DependencyInjection;

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

    public void OpenAiSettings()
    {
        if (_aiSettings is not null) { _aiSettings.Activate(); return; }
        _aiSettings = new AISettingsWindow(_settingsStore,
            _services.GetRequiredService<IKeyStore>(),
            _services.GetRequiredService<KeyTester>());
        _aiSettings.Closed += (_, _) => _aiSettings = null;
        _aiSettings.Activate();
    }

    // The post-recording action pipelines (transcription, TTS, avatar) arrive in later phases; the
    // two-pane window + menu wiring are in place now. Each opens against the latest styled recording.
    public void GenerateCaptions() => OpenAction("Captions",
        "Captions arrive in an upcoming update — transcription and burn-in are next.");
    public void GenerateVoiceover() => OpenAction("Voiceover",
        "Voiceover arrives in an upcoming update — ElevenLabs narration is next.");
    public void GenerateAvatar() => OpenAction("Avatar Presenter",
        "Avatar presenter arrives in an upcoming update — HeyGen integration is next.");

    private void OpenAction(string title, string comingSoon)
    {
        var latest = _services.GetRequiredService<IRecordingStore>().LatestStyled();
        if (latest is null)
        {
            _ = _interaction.ShowMessageAsync("No recording yet",
                "Record something first — post-recording actions run on your latest styled recording.");
            return;
        }
        if (_actionPreview is not null) { _actionPreview.Activate(); return; }
        ActionPreviewWindow.RenderDelegate stub = (_, _, _) => Task.FromResult<string?>(null);
        _actionPreview = new ActionPreviewWindow(title, latest.StyledPath, controls: null, stub, _interaction, comingSoon);
        _actionPreview.Closed += (_, _) => _actionPreview = null;
        _actionPreview.Activate();
    }
}
