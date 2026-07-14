using DemoTape.Domain.Abstractions;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Windows filesystem locations for DemoTape. Recordings go to
/// <c>%USERPROFILE%\Videos\DemoTape</c> (the Windows analogue of macOS <c>~/Movies/DemoTape</c>);
/// settings and logs go to <c>%LOCALAPPDATA%\DemoTape</c>.
/// </summary>
public sealed class PathService : IPathService
{
    public string OutputDirectory
    {
        get
        {
            // Honor a user-chosen output directory if set (read from settings.json directly to
            // avoid a DI cycle with the settings store, which itself depends on this service).
            var overridePath = ReadOutputOverride();
            if (!string.IsNullOrWhiteSpace(overridePath))
            {
                try { Directory.CreateDirectory(overridePath); return overridePath; }
                catch { /* fall back to default */ }
            }
            var videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
            if (string.IsNullOrEmpty(videos))
                videos = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var dir = Path.Combine(videos, "DemoTape");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    private string? ReadOutputOverride()
    {
        try
        {
            var settingsPath = Path.Combine(AppDataDirectory, "settings.json");
            if (!File.Exists(settingsPath)) return null;
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(settingsPath));
            return doc.RootElement.TryGetProperty("outputDirectoryOverride", out var v) ? v.GetString() : null;
        }
        catch { return null; }
    }

    public string AppDataDirectory
    {
        get
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var dir = Path.Combine(local, "DemoTape");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }
}
