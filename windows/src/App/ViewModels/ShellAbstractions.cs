namespace DemoTape.ViewModels;

/// <summary>Recording lifecycle states, mirroring the macOS AppDelegate state machine.</summary>
public enum RecordingState { Idle, Countdown, Recording, Rendering }

/// <summary>
/// Drives the capture + auto-render pipeline. Implemented in the platform layer
/// (Windows.Graphics.Capture + Win2D render). Abstracted so the shell is testable and the
/// heavy pipeline can be delivered as a later slice without changing the shell.
/// </summary>
public interface IRecordingController
{
    RecordingState State { get; }
    event Action<RecordingState>? StateChanged;

    /// <summary>Starts (with countdown) or stops recording depending on current state.</summary>
    Task ToggleAsync();
}

/// <summary>Opens the app's secondary windows. Implemented in the UI layer.</summary>
public interface INavigationService
{
    void OpenWebPublish();
    void OpenBackgroundPicker();
    void OpenWebcamSettings();
    void SelectRecordingArea();
}
