using DemoTape.App.Infrastructure;
using DemoTape.ViewModels;
using Microsoft.Extensions.DependencyInjection;

namespace DemoTape.App.UI;

/// <summary>
/// Opens the app's secondary windows. Only the Web Publish window is implemented in this slice;
/// the background picker, webcam settings, and region selector are planned windows that surface
/// a friendly notice for now (the feature is sequenced, not removed).
/// </summary>
public sealed class WindowNavigationService : INavigationService
{
    private readonly IServiceProvider _services;
    private readonly WindowsUserInteraction _interaction;
    private WebPublishWindow? _webPublish;

    public WindowNavigationService(IServiceProvider services, WindowsUserInteraction interaction)
    {
        _services = services;
        _interaction = interaction;
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

    public void OpenBackgroundPicker() => Planned("Background gallery");
    public void OpenWebcamSettings() => Planned("Webcam settings");
    public void SelectRecordingArea() => Planned("Region selection");

    private void Planned(string feature) =>
        _ = _interaction.ShowMessageAsync(feature, $"{feature} ships with the capture pipeline slice.");
}
