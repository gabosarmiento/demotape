import Foundation

/// Simple UserDefaults-backed preferences toggled from the menu.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var captureMicrophone: Bool {
        get { defaults.object(forKey: "captureMicrophone") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captureMicrophone") }
    }

    static var captureWebcam: Bool {
        get { defaults.object(forKey: "captureWebcam") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "captureWebcam") }
    }

    /// Webcam circle center, normalized to the screen (top-left origin). Default bottom-left.
    static var webcamPositionX: Double {
        get { defaults.object(forKey: "webcamPositionX") as? Double ?? 0.14 }
        set { defaults.set(newValue, forKey: "webcamPositionX") }
    }
    static var webcamPositionY: Double {
        get { defaults.object(forKey: "webcamPositionY") as? Double ?? 0.82 }
        set { defaults.set(newValue, forKey: "webcamPositionY") }
    }
    /// Webcam zoom factor (1.0 = full frame, higher = zoomed in).
    static var webcamZoom: Double {
        get { defaults.object(forKey: "webcamZoom") as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: "webcamZoom") }
    }
    /// Webcam circle diameter as a fraction of screen width (clamped to a normal range).
    static var webcamSize: Double {
        get { defaults.object(forKey: "webcamSize") as? Double ?? 0.22 }
        set { defaults.set(newValue, forKey: "webcamSize") }
    }

    /// Capture a selected region (with framing) instead of the full screen.
    static var useRegion: Bool {
        get { defaults.object(forKey: "useRegion") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "useRegion") }
    }
    /// Selected region, normalized to the display (top-left origin).
    static var regionX: Double { get { defaults.double(forKey: "regionX") } set { defaults.set(newValue, forKey: "regionX") } }
    static var regionY: Double { get { defaults.double(forKey: "regionY") } set { defaults.set(newValue, forKey: "regionY") } }
    static var regionW: Double { get { defaults.object(forKey: "regionW") as? Double ?? 0.6 } set { defaults.set(newValue, forKey: "regionW") } }
    static var regionH: Double { get { defaults.object(forKey: "regionH") as? Double ?? 0.6 } set { defaults.set(newValue, forKey: "regionH") } }

    /// Selected web-publish height tiers (any of 360/480/540/720).
    static var publishTiers: [Int] {
        get { (defaults.array(forKey: "publishTiers") as? [Int]) ?? [540] }
        set { defaults.set(newValue, forKey: "publishTiers") }
    }

    /// Background image file (in the bundled Resources/background folder) for framed mode.
    static var backgroundFile: String {
        get { defaults.string(forKey: "backgroundFile") ?? "gradient_wave_wallpaper_01.png" }
        set { defaults.set(newValue, forKey: "backgroundFile") }
    }

    // MARK: - Captions (AI, bring-your-own-key)

    /// OpenAI-compatible speech-to-text base URL. Default is OpenAI; Groq and other
    /// compatible endpoints work by changing this. The API key lives in the Keychain.
    static var sttBaseURL: String {
        get { defaults.string(forKey: "sttBaseURL") ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: "sttBaseURL") }
    }
    /// Speech-to-text model id (e.g. "whisper-1" for OpenAI, "whisper-large-v3" for Groq).
    static var sttModel: String {
        get { defaults.string(forKey: "sttModel") ?? "whisper-1" }
        set { defaults.set(newValue, forKey: "sttModel") }
    }
    /// Optional ISO-639-1 language hint for transcription ("" = auto-detect).
    static var sttLanguage: String {
        get { defaults.string(forKey: "sttLanguage") ?? "" }
        set { defaults.set(newValue, forKey: "sttLanguage") }
    }
    /// Master switch for AI features. Off by default — the app stays fully local until
    /// the user turns this on and configures a key in AI Settings.
    static var aiEnabled: Bool {
        get { defaults.bool(forKey: "aiEnabled") }
        set { defaults.set(newValue, forKey: "aiEnabled") }
    }
    /// Chosen provider preset name ("OpenAI", "Groq", or "Custom").
    static var aiProvider: String {
        get { defaults.string(forKey: "aiProvider") ?? "OpenAI" }
        set { defaults.set(newValue, forKey: "aiProvider") }
    }

    // MARK: - Voiceover (ElevenLabs, bring-your-own-key)

    /// ElevenLabs TTS model. eleven_multilingual_v2 is a solid default.
    static var elevenModel: String {
        get { defaults.string(forKey: "elevenModel") ?? "eleven_multilingual_v2" }
        set { defaults.set(newValue, forKey: "elevenModel") }
    }
    /// Last-used ElevenLabs voice id + display name (remembered for convenience).
    static var elevenVoiceId: String {
        get { defaults.string(forKey: "elevenVoiceId") ?? "" }
        set { defaults.set(newValue, forKey: "elevenVoiceId") }
    }
    static var elevenVoiceName: String {
        get { defaults.string(forKey: "elevenVoiceName") ?? "" }
        set { defaults.set(newValue, forKey: "elevenVoiceName") }
    }
}
