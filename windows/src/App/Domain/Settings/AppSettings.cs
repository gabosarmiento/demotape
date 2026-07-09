namespace DemoTape.Domain.Settings;

/// <summary>
/// Strongly-typed, serializable preferences POCO. Replaces the macOS <c>UserDefaults</c>-backed
/// <c>Settings</c> enum. Defaults match the original app 1:1 (plus Windows-only additions).
/// Persisted as JSON via <see cref="ISettingsStore"/> (Infrastructure).
/// </summary>
public sealed class AppSettings
{
    public bool CaptureMicrophone { get; set; } = true;
    public bool CaptureWebcam { get; set; }

    /// <summary>Webcam circle center, normalized to the screen (top-left origin). Default bottom-left.</summary>
    public double WebcamPositionX { get; set; } = 0.14;
    public double WebcamPositionY { get; set; } = 0.82;

    /// <summary>Webcam zoom factor (1.0 = full frame, higher = zoomed in).</summary>
    public double WebcamZoom { get; set; } = 1.0;

    /// <summary>Webcam circle diameter as a fraction of screen width (kept small for web demos).</summary>
    public double WebcamSize { get; set; } = 0.16;

    /// <summary>Capture a selected region (with framing) instead of the full screen.</summary>
    public bool UseRegion { get; set; }

    /// <summary>Selected region, normalized to the display (top-left origin).</summary>
    public double RegionX { get; set; }
    public double RegionY { get; set; }
    public double RegionW { get; set; } = 0.6;
    public double RegionH { get; set; } = 0.6;

    /// <summary>Selected web-publish height tiers (any of 360/480/540/720).</summary>
    public List<int> PublishTiers { get; set; } = new() { 540 };

    /// <summary>Background image file (bundled asset name) or an absolute path, for framed mode.</summary>
    public string BackgroundFile { get; set; } = "gradient_wave_wallpaper_01.png";

    // ---- Windows-specific additions ----

    /// <summary>Global record-toggle hotkey. Default Ctrl+Shift+R (Win+Shift+S is reserved).</summary>
    public string ToggleHotkey { get; set; } = "Ctrl+Shift+R";

    /// <summary>Whether to render keyboard-shortcut badges (requires the keystroke hook).</summary>
    public bool ShowShortcutBadges { get; set; } = true;

    public AppSettings Clone() => (AppSettings)MemberwiseClone();
}
