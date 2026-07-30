namespace DemoTape.ViewModels;

/// <summary>Recording lifecycle states, mirroring the macOS AppDelegate state machine.</summary>
/// <remarks><see cref="Armed"/> means a floating control bar is shown and the webcam/mic are
/// warming up, but capture hasn't begun — the user starts it from the bar.</remarks>
public enum RecordingState { Idle, Armed, Countdown, Recording, Rendering }

/// <summary>
/// Drives the capture + auto-render pipeline. Implemented in the platform layer
/// (Windows.Graphics.Capture + Win2D render). Abstracted so the shell is testable and the
/// heavy pipeline can be delivered as a later slice without changing the shell.
/// </summary>
public interface IRecordingController
{
    RecordingState State { get; }
    event Action<RecordingState>? StateChanged;

    /// <summary>Absolute path of the most recent finished (styled) video, or null. Surfaced in the
    /// external <c>control.json</c> so an orchestrator can collect the result.</summary>
    string? LastOutputPath { get; }

    /// <summary>Starts (with countdown) or stops recording depending on current state.</summary>
    Task ToggleAsync();

    /// <summary>
    /// Applies a parsed <c>demotape://</c> control command (from an external orchestrator): starts a
    /// full-screen/region/webcam capture with the given countdown + input overrides, or stops.
    /// Chrome-free (no interactive selector or control bar) so it never appears in an automated take.
    /// </summary>
    Task ApplyControlCommandAsync(DemoTape.Domain.Control.DemoControl.Command command);

    /// <summary>Arms full-screen capture: shows the control bar and warms the webcam/mic.</summary>
    Task ArmFullScreenAsync();

    /// <summary>Shows the region selector; on confirm, arms region capture (bar + bounds overlay).</summary>
    Task ArmRegionAsync();

    /// <summary>Begins the countdown then capture (from the armed state).</summary>
    Task StartAsync();

    /// <summary>Stops recording and renders the styled output.</summary>
    Task StopAsync();

    /// <summary>Cancels an armed session or discards an in-progress recording (no render).</summary>
    Task CancelAsync();
}

/// <summary>Opens the app's secondary windows. Implemented in the UI layer.</summary>
public interface INavigationService
{
    void OpenWebPublish();
    void OpenBackgroundPicker();
    void OpenWebcamSettings();

    /// <summary>Opens the opt-in AI features settings (keys + toggles).</summary>
    void OpenAiSettings();

    /// <summary>Opens the two-pane action window for the given post-recording action.</summary>
    void GenerateCaptions();
    void GenerateVoiceover();
    void GenerateAvatar();
    void AutoCut();

    /// <summary>Opens the About panel (version, permissions, update check).</summary>
    void OpenAbout();

    /// <summary>Opens the branding/watermark settings.</summary>
    void OpenBrandingSettings();

    /// <summary>Prompts for a new recordings output directory.</summary>
    void ChangeOutputDirectory();

    /// <summary>Opens the teleprompter settings (script + speed/size).</summary>
    void OpenTeleprompterSettings();
}
