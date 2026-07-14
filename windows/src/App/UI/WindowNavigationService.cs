using DemoTape.App.Infrastructure;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Ai;
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

        ActionPreviewWindow.RenderDelegate render = async (src, progress, ct) =>
        {
            var outPath = Domain.Ai.VoiceoverPlanner.CaptionedPath(src).Replace(".captioned.mp4", ".tight.mp4");
            return await service.AutoCutAsync(src, outPath, new Infrastructure.AutoCutService.Options(), progress, ct);
        };
        Present(new ActionPreviewWindow("Auto-Cut & Speed Up", latest, controls: null, render, _interaction,
            "Nothing to trim — no long silent gaps were found."));
    }

    private string? LatestOrPrompt()
    {
        var latest = _services.GetRequiredService<IRecordingStore>().LatestStyled();
        if (latest is not null) return latest.StyledPath;
        _ = _interaction.ShowMessageAsync("No recording yet",
            "Record something first — post-recording actions run on your latest styled recording.");
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
