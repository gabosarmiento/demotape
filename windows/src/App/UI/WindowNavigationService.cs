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
}
