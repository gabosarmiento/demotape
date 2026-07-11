import Foundation

/// Preferences for the avatar-presenter feature. Opt-in and off by default; the HeyGen API key
/// lives in the Keychain (see `Keychain.heygenAPIKeyAccount`), never here.
enum AvatarSettings {
    private static let defaults = UserDefaults.standard

    /// Whether the avatar-presenter feature is enabled (a key must also be present).
    static var enabled: Bool {
        get { defaults.bool(forKey: "avatarEnabled") }
        set { defaults.set(newValue, forKey: "avatarEnabled") }
    }

    /// Last-used library avatar id ("" = none / use photo).
    static var avatarId: String {
        get { defaults.string(forKey: "avatarId") ?? "" }
        set { defaults.set(newValue, forKey: "avatarId") }
    }
    static var avatarName: String {
        get { defaults.string(forKey: "avatarName") ?? "" }
        set { defaults.set(newValue, forKey: "avatarName") }
    }

    /// Composited position over the screen video.
    static var position: AvatarPosition {
        get { AvatarPosition(rawValue: defaults.string(forKey: "avatarPosition") ?? "") ?? .bottomRight }
        set { defaults.set(newValue.rawValue, forKey: "avatarPosition") }
    }

    /// Avatar height as a fraction of the video height (0.2–0.6). Default 0.34.
    static var sizeFraction: Double {
        get { let v = defaults.object(forKey: "avatarSizeFraction") as? Double ?? 0.34; return min(max(v, 0.2), 0.6) }
        set { defaults.set(min(max(newValue, 0.2), 0.6), forKey: "avatarSizeFraction") }
    }

    /// Output quality requested from the provider. Default 720p — the avatar ends up small in a
    /// PiP circle, so higher resolutions mostly waste credits/time. Configurable in AI Settings.
    static var quality: AvatarQuality {
        get { AvatarQuality(rawValue: defaults.string(forKey: "avatarQuality") ?? "") ?? .p720 }
        set { defaults.set(newValue.rawValue, forKey: "avatarQuality") }
    }

    /// Optional body-motion prompt (photo avatars only).
    static var motionPrompt: String {
        get { defaults.string(forKey: "avatarMotionPrompt") ?? "" }
        set { defaults.set(newValue, forKey: "avatarMotionPrompt") }
    }

    /// Chroma-key background color (hex) used for generation + keyed out on composite.
    static var chromaKeyHex: String {
        get { defaults.string(forKey: "avatarChromaKeyHex") ?? "#00B140" }
        set { defaults.set(newValue, forKey: "avatarChromaKeyHex") }
    }
}
