import AppKit

/// A recording-area preset: an aspect-ratio lock plus a target export size. Selecting one on
/// the area-selection screen constrains the drag to that shape and scales the export to the
/// target dimensions. "Freeform" applies no lock.
struct AreaPreset {
    let name: String     // full name (tooltip)
    let short: String    // chip label
    let rw: CGFloat      // aspect numerator (0 = freeform)
    let rh: CGFloat
    let targetW: Int
    let targetH: Int

    var isFreeform: Bool { rw <= 0 || rh <= 0 }
    var aspect: CGFloat? { isFreeform ? nil : rw / rh }
    var targetSize: CGSize? { (targetW > 0 && targetH > 0) ? CGSize(width: targetW, height: targetH) : nil }

    // One preset per distinct shape. The web delivery resolution (540p/720p…) is chosen later
    // in Web Publish, so we don't duplicate 16:9 here.
    static let all: [AreaPreset] = [
        AreaPreset(name: "Freeform", short: "Free", rw: 0, rh: 0, targetW: 0, targetH: 0),
        AreaPreset(name: "Portrait · 4:5 · 1080×1350 (LinkedIn feed)", short: "4:5", rw: 4, rh: 5, targetW: 1080, targetH: 1350),
        AreaPreset(name: "Square · 1:1 · 1080×1080", short: "1:1", rw: 1, rh: 1, targetW: 1080, targetH: 1080),
        AreaPreset(name: "Landscape · 16:9 · 1920×1080 (web/embed)", short: "16:9", rw: 16, rh: 9, targetW: 1920, targetH: 1080),
        AreaPreset(name: "Vertical · 9:16 · 1080×1920 (Reels/Shorts)", short: "9:16", rw: 9, rh: 16, targetW: 1080, targetH: 1920),
    ]

    static func named(_ n: String) -> AreaPreset { all.first { $0.name == n } ?? all[0] }

    /// A small rounded-rect glyph illustrating this aspect ratio.
    func icon(box: CGFloat = 34, color: NSColor = .white) -> NSImage {
        let img = NSImage(size: NSSize(width: box, height: box))
        img.lockFocus()
        let a = aspect ?? 1
        var w = box - 10, h = box - 10
        if a >= 1 { h = w / a } else { w = h * a }
        let rect = NSRect(x: (box - w) / 2, y: (box - h) / 2, width: w, height: h)
        let p = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        p.lineWidth = 1.8
        color.setStroke()
        if isFreeform { p.setLineDash([3, 2.5], count: 2, phase: 0) }
        p.stroke()
        img.unlockFocus()
        return img
    }
}
