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

    // ---- AI features (opt-in, bring-your-own-key; secrets live in Credential Manager, not here) ----

    /// <summary>Captions (speech-to-text) enabled. Off by default; requires a stored key.</summary>
    public bool CaptionsEnabled { get; set; }

    /// <summary>Voiceover (ElevenLabs TTS) enabled. Off by default; requires a stored key.</summary>
    public bool VoiceoverEnabled { get; set; }

    /// <summary>Selected STT provider preset name (OpenAI / Groq / Custom).</summary>
    public string AiProvider { get; set; } = "OpenAI";

    /// <summary>STT (transcription) API base URL.</summary>
    public string SttBaseUrl { get; set; } = "https://api.openai.com/v1";

    /// <summary>STT model id.</summary>
    public string SttModel { get; set; } = "whisper-1";

    /// <summary>Optional ISO language hint for transcription (empty = auto-detect).</summary>
    public string SttLanguage { get; set; } = "";

    /// <summary>On-device Smart Noise Suppression applied to the mic before muxing (off by default).</summary>
    public bool NoiseSuppression { get; set; }

    /// <summary>On-device Enhance Voice (studio EQ + compressor) applied to the mic (off by default).</summary>
    public bool EnhanceVoice { get; set; }

    /// <summary>Auto-zoom the styled render toward activity (clicks/typing). On by default.</summary>
    public bool AutoZoom { get; set; } = true;

    /// <summary>Custom recordings output directory (empty = default %USERPROFILE%\Videos\DemoTape).</summary>
    public string OutputDirectoryOverride { get; set; } = "";

    // ---- Teleprompter (on-screen scrolling script during recording; excluded from capture) ----
    public bool TeleprompterEnabled { get; set; }
    public string TeleprompterScript { get; set; } = "";
    /// <summary>Scroll speed in pixels/second.</summary>
    public double TeleprompterSpeed { get; set; } = 40;
    public double TeleprompterFontSize { get; set; } = 26;

    // ---- Branding / watermark ----

    /// <summary>Bake a logo watermark into the styled output.</summary>
    public bool BrandingEnabled { get; set; }

    /// <summary>Absolute path to the branding logo (PNG with transparency recommended).</summary>
    public string BrandingImagePath { get; set; } = "";

    /// <summary>Watermark corner: TopLeft, TopRight, BottomLeft, BottomRight.</summary>
    public string BrandingPosition { get; set; } = "BottomRight";

    /// <summary>Watermark opacity 0..1.</summary>
    public double BrandingOpacity { get; set; } = 0.9;

    /// <summary>Watermark width as a fraction of the output width.</summary>
    public double BrandingScale { get; set; } = 0.16;

    public AppSettings Clone() => (AppSettings)MemberwiseClone();
}
