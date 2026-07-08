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
            var videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
            if (string.IsNullOrEmpty(videos))
                videos = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var dir = Path.Combine(videos, "DemoTape");
            Directory.CreateDirectory(dir);
            return dir;
        }
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
