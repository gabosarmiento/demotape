import Foundation

/// Simple UserDefaults-backed preferences toggled from the menu.
enum Settings {
    private static let defaults = UserDefaults.standard

    // MARK: - System preferences

    /// Show a Dock icon (regular app) instead of running menu-bar-only. Default off.
    static var showInDock: Bool {
        get { defaults.bool(forKey: "showInDock") }
        set { defaults.set(newValue, forKey: "showInDock") }
    }
    /// Apply spring-physics auto-zoom on clicks/typing during the styled render. Default on.
    static var autoZoomEnabled: Bool {
        get { defaults.object(forKey: "autoZoomEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoZoomEnabled") }
    }
    /// "Demo mode": keep DemoTape's own menu/config/action items active while a recording is in
    /// progress, so you can record a walkthrough *of DemoTape itself* (showing off its features).
    /// Normally these are greyed out while recording. Default off.
    static var allowSelfRecording: Bool {
        get { defaults.bool(forKey: "allowSelfRecording") }
        set { defaults.set(newValue, forKey: "allowSelfRecording") }
    }
    /// Set once the first-run welcome/onboarding has been completed.
    static var didCompleteOnboarding: Bool {
        get { defaults.bool(forKey: "didCompleteOnboarding") }
        set { defaults.set(newValue, forKey: "didCompleteOnboarding") }
    }
    /// How many times the welcome screen has been shown.
    static var welcomeShowCount: Int {
        get { defaults.integer(forKey: "welcomeShowCount") }
        set { defaults.set(newValue, forKey: "welcomeShowCount") }
    }
    /// When the welcome screen was last shown (seconds since 1970).
    static var welcomeLastShown: Double {
        get { defaults.double(forKey: "welcomeLastShown") }
        set { defaults.set(newValue, forKey: "welcomeLastShown") }
    }
    /// Show the welcome for the first few launches, then only ~monthly, so it doesn't nag.
    static var shouldShowWelcome: Bool {
        if welcomeShowCount < 3 { return true }
        let monthSeconds: Double = 30 * 24 * 60 * 60
        return (Date().timeIntervalSince1970 - welcomeLastShown) > monthSeconds
    }
    static func markWelcomeShown() {
        welcomeShowCount += 1
        welcomeLastShown = Date().timeIntervalSince1970
    }

    static var captureMicrophone: Bool {
        get { defaults.object(forKey: "captureMicrophone") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captureMicrophone") }
    }

    /// Capture system (output) audio natively. Only meaningful on macOS 13+ (SCK); the UI hides the
    /// toggle on older systems, where system audio is captured via a loopback device instead.
    static var captureSystemAudio: Bool {
        get { defaults.object(forKey: "captureSystemAudio") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "captureSystemAudio") }
    }

    /// Smart noise suppression: clean steady background noise from the mic during the styled
    /// render. Simple on/off; applied at a fixed strong level. On-device (Accelerate), no network.
    static var noiseSuppressionEnabled: Bool {
        get { defaults.bool(forKey: "noiseSuppressionEnabled") }
        set { defaults.set(newValue, forKey: "noiseSuppressionEnabled") }
    }

    /// Studio-voice enhancement: EQ + compression to make the mic sound warmer and more present.
    /// Simple on/off, applied after noise suppression during the render. On-device, no network.
    static var enhanceVoiceEnabled: Bool {
        get { defaults.bool(forKey: "enhanceVoiceEnabled") }
        set { defaults.set(newValue, forKey: "enhanceVoiceEnabled") }
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
    /// Selected recording-area preset name (aspect lock + target export size). "Freeform" = none.
    static var regionPreset: String {
        get { defaults.string(forKey: "regionPreset") ?? "Freeform" }
        set { defaults.set(newValue, forKey: "regionPreset") }
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

    /// Web Publish: also export an animated GIF, and its width/fps.
    static var publishGIF: Bool {
        get { defaults.bool(forKey: "publishGIF") }
        set { defaults.set(newValue, forKey: "publishGIF") }
    }
    /// GIF quality preset name: "Smaller", "Balanced" (default), or "Sharp".
    static var gifQuality: String {
        get { defaults.string(forKey: "gifQuality") ?? "Balanced" }
        set { defaults.set(newValue, forKey: "gifQuality") }
    }

    /// Background image file (in the bundled Resources/background folder) for framed mode.
    static var backgroundFile: String {
        get { defaults.string(forKey: "backgroundFile") ?? "gradient_wave_wallpaper_01.png" }
        set { defaults.set(newValue, forKey: "backgroundFile") }
    }
    /// Whether a region recording is framed on a background. Off = "No Background": record the
    /// selected area at its own resolution, edge-to-edge, keeping proportions.
    static var framedBackground: Bool {
        get { defaults.object(forKey: "framedBackground") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "framedBackground") }
    }

    // MARK: - Branding (logo watermark)

    static var brandingEnabled: Bool {
        get { defaults.bool(forKey: "brandingEnabled") }
        set { defaults.set(newValue, forKey: "brandingEnabled") }
    }
    /// Absolute path to the user's logo image ("" = none).
    static var brandingImagePath: String {
        get { defaults.string(forKey: "brandingImagePath") ?? "" }
        set { defaults.set(newValue, forKey: "brandingImagePath") }
    }
    /// Logo center, normalized to the output (top-left origin). Default bottom-right.
    static var brandingCenterX: Double {
        get { defaults.object(forKey: "brandingCenterX") as? Double ?? 0.86 }
        set { defaults.set(newValue, forKey: "brandingCenterX") }
    }
    static var brandingCenterY: Double {
        get { defaults.object(forKey: "brandingCenterY") as? Double ?? 0.90 }
        set { defaults.set(newValue, forKey: "brandingCenterY") }
    }
    /// Logo width as a fraction of the output width.
    static var brandingWidthFraction: Double {
        get { defaults.object(forKey: "brandingWidthFraction") as? Double ?? 0.14 }
        set { defaults.set(newValue, forKey: "brandingWidthFraction") }
    }

    // MARK: - Teleprompter

    static var teleprompterEnabled: Bool {
        get { defaults.bool(forKey: "teleprompterEnabled") }
        set { defaults.set(newValue, forKey: "teleprompterEnabled") }
    }
    static var teleprompterText: String {
        get { defaults.string(forKey: "teleprompterText") ?? "" }
        set { defaults.set(newValue, forKey: "teleprompterText") }
    }
    /// How long (minutes) the script takes to scroll — used only in "fit to duration" mode.
    static var teleprompterMinutes: Double {
        get { defaults.object(forKey: "teleprompterMinutes") as? Double ?? 3.0 }
        set { defaults.set(newValue, forKey: "teleprompterMinutes") }
    }
    /// Scroll speed multiplier (1.0 = a natural reading pace). Used unless "fit to duration".
    static var teleprompterSpeed: Double {
        get { defaults.object(forKey: "teleprompterSpeed") as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: "teleprompterSpeed") }
    }
    /// When true, scroll the whole script to fit `teleprompterMinutes` instead of using speed.
    static var teleprompterFitDuration: Bool {
        get { defaults.bool(forKey: "teleprompterFitDuration") }
        set { defaults.set(newValue, forKey: "teleprompterFitDuration") }
    }
    /// Fraction of the screen reserved for the teleprompter strip in full-screen mode
    /// (kept thin; this strip is excluded from the recording).
    static let teleprompterTopStripFraction: Double = 0.12
    /// Which edge the full-screen teleprompter strip sits on: "top" (default), "bottom",
    /// "left", or "right".
    static var teleprompterStripEdge: String {
        get { defaults.string(forKey: "teleprompterStripEdge") ?? "top" }
        set { defaults.set(newValue, forKey: "teleprompterStripEdge") }
    }

    /// The teleprompter will actually show (enabled + has a script).
    static var teleprompterActive: Bool {
        teleprompterEnabled && !teleprompterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Output directory

    /// Custom output directory ("" = default ~/Movies/DemoTape). Persisted across launches.
    static var outputDirectoryPath: String {
        get { defaults.string(forKey: "outputDirectoryPath") ?? "" }
        set { defaults.set(newValue, forKey: "outputDirectoryPath") }
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
    /// Chosen audio **input** device `uniqueID` for recording ("" = system default). Set this to a
    /// loopback driver (BlackHole/Loopback) to capture system audio on older macOS.
    static var audioInputDeviceID: String {
        get { defaults.string(forKey: "audioInputDeviceID") ?? "" }
        set { defaults.set(newValue, forKey: "audioInputDeviceID") }
    }
    /// Optional ISO-639-1 language hint for transcription ("" = auto-detect).
    static var sttLanguage: String {
        get { defaults.string(forKey: "sttLanguage") ?? "" }
        set { defaults.set(newValue, forKey: "sttLanguage") }
    }
    /// Master switch for AI features. Off by default — the app stays fully local until
    /// the user turns this on and configures a key in AI Settings.
    ///
    /// Kept as a convenience that reflects whether *either* feature is on. Captions and
    /// voiceover are enabled independently (see `captionsEnabled` / `voiceoverEnabled`).
    static var aiEnabled: Bool {
        get { captionsEnabled || voiceoverEnabled }
        set { /* legacy no-op: features are toggled independently now */ }
    }
    /// Captions (speech-to-text) enabled. Off by default; turned on once a key is ready.
    static var captionsEnabled: Bool {
        get { defaults.bool(forKey: "captionsEnabled") }
        set { defaults.set(newValue, forKey: "captionsEnabled") }
    }
    /// Voiceover (ElevenLabs) enabled. Off by default; turned on once a key is ready.
    static var voiceoverEnabled: Bool {
        get { defaults.bool(forKey: "voiceoverEnabled") }
        set { defaults.set(newValue, forKey: "voiceoverEnabled") }
    }
    /// Gender of the last-used ElevenLabs voice ("male"/"female"/""), used to auto-match an avatar.
    static var elevenVoiceGender: String {
        get { defaults.string(forKey: "elevenVoiceGender") ?? "" }
        set { defaults.set(newValue, forKey: "elevenVoiceGender") }
    }
    /// Chosen provider preset name ("OpenAI", "Groq", "Local (OpenAI-compatible)", or "Custom").
    static var aiProvider: String {
        get { defaults.string(forKey: "aiProvider") ?? "OpenAI" }
        set { defaults.set(newValue, forKey: "aiProvider") }
    }
    /// True when the speech-to-text endpoint is a local server (localhost), which needs no API key.
    /// Lets captions run fully offline against e.g. faster-whisper-server / speaches / LocalAI.
    static var sttKeyOptional: Bool { isLocalHost(urlString: sttBaseURL) }

    /// Heuristic: does this URL point at a machine-local server (loopback)? Used to decide when an
    /// API key is optional for a bring-your-own-endpoint AI feature.
    static func isLocalHost(urlString: String) -> Bool {
        guard let host = URLComponents(string: urlString.trimmingCharacters(in: .whitespaces))?.host?.lowercased()
        else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
            || host == "::1" || host.hasSuffix(".local")
    }
    /// Chat model used by the AI Director to reason over the transcript + activity. Uses the same
    /// endpoint/key as captions. Default suits OpenAI; change for other providers.
    static var aiDirectorModel: String {
        get { defaults.string(forKey: "aiDirectorModel") ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: "aiDirectorModel") }
    }

    // MARK: - Voiceover (bring-your-own-key OR local, pluggable provider)

    /// TTS provider preset name: "ElevenLabs" (hosted, paid), "OpenAI-compatible" (the standard
    /// `/v1/audio/speech` contract — works with LocalAI, Kokoro-FastAPI, openedai-speech, or any
    /// local Docker server that speaks it), or "Custom" (a raw HTTP endpoint returning audio bytes).
    /// Default is ElevenLabs so existing setups keep working untouched.
    static var ttsProvider: String {
        get { defaults.string(forKey: "ttsProvider") ?? "ElevenLabs" }
        set { defaults.set(newValue, forKey: "ttsProvider") }
    }
    /// Base URL for the OpenAI-compatible/custom providers, e.g. "http://localhost:8880/v1"
    /// (Kokoro-FastAPI) or "http://localhost:8080/v1" (LocalAI). Ignored for ElevenLabs, which
    /// uses its fixed endpoint. The API key (if any) lives in the Keychain.
    static var ttsBaseURL: String {
        get { defaults.string(forKey: "ttsBaseURL") ?? "http://localhost:8880/v1" }
        set { defaults.set(newValue, forKey: "ttsBaseURL") }
    }
    /// TTS model id for the OpenAI-compatible/custom providers (e.g. "tts-1", "kokoro").
    static var ttsModel: String {
        get { defaults.string(forKey: "ttsModel") ?? "tts-1" }
        set { defaults.set(newValue, forKey: "ttsModel") }
    }
    /// Voice name/id used by the OpenAI-compatible/custom providers (e.g. "alloy", "af_bella").
    /// ElevenLabs voices are chosen from its live voice list and stored in `elevenVoiceId`.
    static var ttsVoice: String {
        get { defaults.string(forKey: "ttsVoice") ?? "alloy" }
        set { defaults.set(newValue, forKey: "ttsVoice") }
    }

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
