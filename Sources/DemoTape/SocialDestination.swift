import AppKit

/// The "Optimize for social media" options. Each is one of the existing **social** `AreaPreset`s
/// (platform name + aspect + target size + tint), so nothing about aspect math or export sizes is
/// duplicated.
///
/// The capture owns the ratio. In **Select Area** the framed area's aspect has priority, so only the
/// platforms matching that ratio are offered (pick a 16:9 area → only 16:9 destinations). **Webcam-
/// only** and **Full Screen** have no framed area, so every platform is offered and the chosen one
/// center-crops the export to that shape.
enum SocialDestination {

    /// All platform options (reusing the social presets).
    static var all: [AreaPreset] { AreaPreset.social }

    /// Options to offer for a capture of the given aspect (w/h). `nil` = no locked aspect
    /// (webcam-only / full-screen) → every platform.
    static func options(forAspect aspect: CGFloat?) -> [AreaPreset] {
        guard let a = aspect else { return all }
        return all.filter { preset in
            guard let pa = preset.aspect else { return false }
            return abs(pa - a) < 0.02
        }
    }

    /// Whether `name` is a valid option for the given aspect.
    static func isCompatible(_ name: String, aspect: CGFloat?) -> Bool {
        options(forAspect: aspect).contains { $0.name == name }
    }

    /// A sensible default option for the given aspect (first matching platform).
    static func defaultName(forAspect aspect: CGFloat?) -> String {
        options(forAspect: aspect).first?.name ?? all[0].name
    }

    /// Short filename slug for a chosen destination, e.g.
    /// "TikTok · 9:16 · 1080×1920" → "tiktok", "Instagram Reel · 9:16 · …" → "instagram-reel".
    static func slug(_ name: String) -> String {
        let base = name.split(separator: "·").first.map(String.init) ?? name
        let lowered = base.lowercased()
        let scalars = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let parts = String(scalars).split(separator: "-").filter { !$0.isEmpty }
        return parts.isEmpty ? "social" : parts.joined(separator: "-")
    }
}
