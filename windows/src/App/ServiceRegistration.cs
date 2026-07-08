using DemoTape.App.Infrastructure;
using DemoTape.App.UI;
using DemoTape.Domain.Abstractions;
using DemoTape.Services;
using DemoTape.ViewModels;
using Microsoft.Extensions.DependencyInjection;

namespace DemoTape.App;

/// <summary>
/// Composition root: wires domain abstractions to their Windows implementations. Keeping this
/// in one place makes the dependency graph obvious and the layers cleanly swappable.
/// </summary>
public static class ServiceRegistration
{
    public static IServiceCollection AddDemoTape(this IServiceCollection services)
    {
        // Infrastructure (platform implementations of Domain abstractions)
        services.AddSingleton<IPathService, PathService>();
        services.AddSingleton<ISettingsStore, JsonSettingsStore>();
        services.AddSingleton<IVideoTranscoder, MediaFoundationTranscoder>();
        services.AddSingleton<IRecordingStore, FileRecordingStore>();
        services.AddSingleton<WindowsUserInteraction>();
        services.AddSingleton<IUserInteraction>(sp => sp.GetRequiredService<WindowsUserInteraction>());

        // Application services (portable orchestration)
        services.AddSingleton<WebPublishService>();

        // Shell wiring
        services.AddSingleton<IRecordingController, DeferredRecordingController>();
        services.AddSingleton<INavigationService, WindowNavigationService>();

        // ViewModels
        services.AddSingleton<ShellViewModel>();
        services.AddTransient<WebPublishViewModel>();

        return services;
    }
}
