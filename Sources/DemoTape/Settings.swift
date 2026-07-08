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
}
