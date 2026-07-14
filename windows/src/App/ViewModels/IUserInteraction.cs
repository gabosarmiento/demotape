namespace DemoTape.ViewModels;

/// <summary>
/// Platform-facing interactions the ViewModels need but that live in the UI layer
/// (revealing a folder in Explorer, showing a message). Kept as an interface so the
/// ViewModels stay unit-testable with a fake implementation.
/// </summary>
public interface IUserInteraction
{
    /// <summary>Reveals a file or folder in Windows Explorer.</summary>
    void RevealInExplorer(string path);

    /// <summary>Shows a transient message (dialog or tray notification).</summary>
    Task ShowMessageAsync(string title, string message);

    /// <summary>Shows a non-blocking tray notification (balloon), for background events.</summary>
    void Notify(string title, string message);
}
