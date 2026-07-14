using System.Text.Json;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Settings;
using Microsoft.Extensions.Logging;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Persists <see cref="AppSettings"/> as <c>settings.json</c> in <c>%LOCALAPPDATA%\DemoTape</c>.
/// Replaces the macOS <c>UserDefaults</c> store. Reads/writes are resilient: a missing or
/// corrupt file falls back to defaults rather than throwing.
/// </summary>
public sealed class JsonSettingsStore : ISettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly string _path;
    private readonly ILogger<JsonSettingsStore> _logger;
    private readonly object _gate = new();

    public JsonSettingsStore(IPathService paths, ILogger<JsonSettingsStore> logger)
    {
        _path = Path.Combine(paths.AppDataDirectory, "settings.json");
        _logger = logger;
    }

    public AppSettings Load()
    {
        lock (_gate)
        {
            try
            {
                if (!File.Exists(_path)) return new AppSettings();
                var json = File.ReadAllText(_path);
                return JsonSerializer.Deserialize<AppSettings>(json, Options) ?? new AppSettings();
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to read settings; using defaults");
                return new AppSettings();
            }
        }
    }

    public void Save(AppSettings settings)
    {
        lock (_gate)
        {
            try
            {
                var json = JsonSerializer.Serialize(settings, Options);
                File.WriteAllText(_path, json);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to write settings");
            }
        }
    }
}
