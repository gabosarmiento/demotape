import AppKit

/// A recording-area preset: an aspect-ratio lock plus a target export size. Selecting one on
/// the area-selection screen constrains the drag to that shape and scales the export to the
/// target dimensions. "Freeform" applies no lock.
///
/// Presets fall into two rows: **general** aspect ratios, and **social** platform presets
/// (YouTube, TikTok, Instagram, LinkedIn, Facebook) that map to the same shapes but carry a
/// platform name + tint so people can pick by destination rather than by math.
struct AreaPreset {
    enum Category { case general, social }

    let name: String       // full name (tooltip / persisted id)
    let short: String      // chip label
    let rw: CGFloat        // aspect numerator (0 = freeform)
    let rh: CGFloat
    let targetW: Int
    let targetH: Int
    let category: Category
    let tintHex: String?   // platform tint for social chips; nil = white

    init(name: String, short: String, rw: CGFloat, rh: CGFloat, targetW: Int, targetH: Int,
         category: Category = .general, tintHex: String? = nil) {
        self.name = name; self.short = short; self.rw = rw; self.rh = rh
        self.targetW = targetW; self.targetH = targetH
        self.category = category; self.tintHex = tintHex
    }

    var isFreeform: Bool { rw <= 0 || rh <= 0 }
    var aspect: CGFloat? { isFreeform ? nil : rw / rh }
    var targetSize: CGSize? { (targetW > 0 && targetH > 0) ? CGSize(width: targetW, height: targetH) : nil }
    var tint: NSColor { tintHex.flatMap { NSColor(hex: $0) } ?? .white }

    // General aspect ratios (top row). Web delivery resolution is chosen later in Web Publish.
    static let general: [AreaPreset] = [
        AreaPreset(name: "Freeform", short: "Free", rw: 0, rh: 0, targetW: 0, targetH: 0),
        AreaPreset(name: "Landscape · 16:9 · 1920×1080", short: "16:9", rw: 16, rh: 9, targetW: 1920, targetH: 1080),
        AreaPreset(name: "Vertical · 9:16 · 1080×1920", short: "9:16", rw: 9, rh: 16, targetW: 1080, targetH: 1920),
        AreaPreset(name: "Square · 1:1 · 1080×1080", short: "1:1", rw: 1, rh: 1, targetW: 1080, targetH: 1080),
        AreaPreset(name: "Portrait · 4:5 · 1080×1350", short: "4:5", rw: 4, rh: 5, targetW: 1080, targetH: 1350),
        AreaPreset(name: "Landscape · 5:4 · 1350×1080", short: "5:4", rw: 5, rh: 4, targetW: 1350, targetH: 1080),
    ]

    // Social platform presets (bottom row).
    static let social: [AreaPreset] = [
        AreaPreset(name: "YouTube · 16:9 · 1920×1080", short: "YouTube", rw: 16, rh: 9,
                   targetW: 1920, targetH: 1080, category: .social, tintHex: "#FF0000"),
        AreaPreset(name: "YouTube Shorts · 9:16 · 1080×1920", short: "Shorts", rw: 9, rh: 16,
                   targetW: 1080, targetH: 1920, category: .social, tintHex: "#FF0000"),
        AreaPreset(name: "TikTok · 9:16 · 1080×1920", short: "TikTok", rw: 9, rh: 16,
                   targetW: 1080, targetH: 1920, category: .social, tintHex: "#FE2C55"),
        AreaPreset(name: "Instagram Reel · 9:16 · 1080×1920", short: "IG Reel", rw: 9, rh: 16,
                   targetW: 1080, targetH: 1920, category: .social, tintHex: "#E1306C"),
        AreaPreset(name: "Instagram Story · 9:16 · 1080×1920", short: "IG Story", rw: 9, rh: 16,
                   targetW: 1080, targetH: 1920, category: .social, tintHex: "#E1306C"),
        AreaPreset(name: "Instagram Post · 1:1 · 1080×1080", short: "IG Post", rw: 1, rh: 1,
                   targetW: 1080, targetH: 1080, category: .social, tintHex: "#E1306C"),
        AreaPreset(name: "LinkedIn Video · 9:16 · 1080×1920", short: "LinkedIn", rw: 9, rh: 16,
                   targetW: 1080, targetH: 1920, category: .social, tintHex: "#0A66C2"),
        AreaPreset(name: "LinkedIn Post · 1:1 · 1080×1080", short: "LI Post", rw: 1, rh: 1,
                   targetW: 1080, targetH: 1080, category: .social, tintHex: "#0A66C2"),
        AreaPreset(name: "Facebook Video · 9:16 · 1080×1920", short: "FB Video", rw: 9, rh: 16,
                   targetW: 1080, targetH: 1920, category: .social, tintHex: "#1877F2"),
        AreaPreset(name: "Facebook Post · 1:1 · 1080×1080", short: "FB Post", rw: 1, rh: 1,
                   targetW: 1080, targetH: 1080, category: .social, tintHex: "#1877F2"),
    ]

    static let all: [AreaPreset] = general + social

    static func named(_ n: String) -> AreaPreset { all.first { $0.name == n } ?? all[0] }

    /// A small rounded-rect glyph illustrating this aspect ratio, tinted by the preset (white for
    /// general, platform color for social — social chips also get a soft fill so they read as a set).
    func icon(box: CGFloat = 34, color: NSColor? = nil) -> NSImage {
        let stroke = color ?? tint
        let img = NSImage(size: NSSize(width: box, height: box))
        img.lockFocus()
        let a = aspect ?? 1
        var w = box - 12, h = box - 12
        if a >= 1 { h = w / a } else { w = h * a }
        let rect = NSRect(x: (box - w) / 2, y: (box - h) / 2, width: w, height: h)
        let p = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        p.lineWidth = 1.8
        if isFreeform { p.setLineDash([3, 2.5], count: 2, phase: 0) }
        if category == .social {
            stroke.withAlphaComponent(0.22).setFill()
            p.fill()
        }
        stroke.setStroke()
        p.stroke()
        img.unlockFocus()
        return img
    }
}
