import AppKit
import CoreText

/// Where captions sit vertically (fraction from the top of the frame).
enum CaptionPosition { case center, lowerThird, bottom }

/// A caption look. **Animated** styles use per-word timing (pop-in / karaoke highlight); the
/// others are static phrase styles. All are burned in by `CaptionBurner`.
struct CaptionStyle {
    let id: String
    let name: String
    let animated: Bool

    // Typography
    let fontName: String
    let uppercase: Bool
    let baseHex: String            // normal word color
    let activeHex: String          // spoken/active word color (animated)
    let futureHex: String?         // upcoming words (karaoke greying); nil = same as base
    let outline: Bool
    let outlineHex: String
    let boxHex: String?            // rounded background box; nil = none

    // Behavior
    let revealFuture: Bool         // false = future words hidden (they pop in); true = shown
    let scaleActive: Bool          // bump the active word
    let baseMaxWordsPerLine: Int
    let position: CaptionPosition

    // MARK: Colors / font

    func color(_ hex: String) -> NSColor { NSColor(hex: hex) ?? .white }
    var baseColor: NSColor { color(baseHex) }
    var activeColor: NSColor { color(activeHex) }
    var futureColor: NSColor { futureHex.map(color) ?? baseColor }
    var outlineColor: NSColor { color(outlineHex) }
    var boxColor: NSColor? { boxHex.map(color) }

    func font(size: CGFloat) -> NSFont {
        NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size, weight: .heavy)
    }

    /// Words per line, tightened for tall/mobile aspect ratios (1:1, 4:5, 9:16) where captions
    /// should be short and punchy.
    func maxWordsPerLine(forAspect aspect: CGFloat) -> Int {
        aspect <= 1.05 ? max(1, min(baseMaxWordsPerLine, 2)) : baseMaxWordsPerLine
    }

    // MARK: - Catalog (4 animated + 4 static)

    static let all: [CaptionStyle] = [pop, karaoke, highlightYellow, highlightGreen,
                                      clean, bold, minimal, boxed]
    static func byID(_ id: String) -> CaptionStyle { all.first { $0.id == id } ?? clean }

    // Animated
    static let pop = CaptionStyle(
        id: "pop", name: "Pop", animated: true, fontName: "AvenirNext-Heavy", uppercase: true,
        baseHex: "#F0641E", activeHex: "#FFC400", futureHex: nil, outline: true, outlineHex: "#1A0E00",
        boxHex: nil, revealFuture: false, scaleActive: true, baseMaxWordsPerLine: 3, position: .center)

    static let karaoke = CaptionStyle(
        id: "karaoke", name: "Karaoke", animated: true, fontName: "AvenirNext-Bold", uppercase: false,
        baseHex: "#141414", activeHex: "#0A0A0A", futureHex: "#9A9A9A", outline: false, outlineHex: "#000000",
        boxHex: "#F4F4F2E6", revealFuture: true, scaleActive: false, baseMaxWordsPerLine: 4, position: .lowerThird)

    static let highlightYellow = CaptionStyle(
        id: "highlight-yellow", name: "Highlight", animated: true, fontName: "AvenirNext-Heavy", uppercase: true,
        baseHex: "#FFFFFF", activeHex: "#FFD400", futureHex: nil, outline: true, outlineHex: "#101010",
        boxHex: nil, revealFuture: true, scaleActive: true, baseMaxWordsPerLine: 3, position: .center)

    static let highlightGreen = CaptionStyle(
        id: "highlight-green", name: "Pop Green", animated: true, fontName: "AvenirNext-Heavy", uppercase: true,
        baseHex: "#FFFFFF", activeHex: "#33E06A", futureHex: nil, outline: true, outlineHex: "#0A1E10",
        boxHex: nil, revealFuture: false, scaleActive: true, baseMaxWordsPerLine: 2, position: .center)

    // Static
    static let clean = CaptionStyle(
        id: "clean", name: "Clean", animated: false, fontName: "HelveticaNeue-Bold", uppercase: false,
        baseHex: "#FFFFFF", activeHex: "#FFFFFF", futureHex: nil, outline: false, outlineHex: "#000000",
        boxHex: "#0000008C", revealFuture: true, scaleActive: false, baseMaxWordsPerLine: 6, position: .bottom)

    static let bold = CaptionStyle(
        id: "bold", name: "Bold", animated: false, fontName: "AvenirNext-Heavy", uppercase: true,
        baseHex: "#FFFFFF", activeHex: "#FFFFFF", futureHex: nil, outline: true, outlineHex: "#101010",
        boxHex: nil, revealFuture: true, scaleActive: false, baseMaxWordsPerLine: 4, position: .lowerThird)

    static let minimal = CaptionStyle(
        id: "minimal", name: "Minimal", animated: false, fontName: "HelveticaNeue-Medium", uppercase: false,
        baseHex: "#FFFFFF", activeHex: "#FFFFFF", futureHex: nil, outline: true, outlineHex: "#0000009C",
        boxHex: nil, revealFuture: true, scaleActive: false, baseMaxWordsPerLine: 7, position: .bottom)

    static let boxed = CaptionStyle(
        id: "boxed", name: "Boxed", animated: false, fontName: "AvenirNext-Bold", uppercase: true,
        baseHex: "#FFFFFF", activeHex: "#FFFFFF", futureHex: nil, outline: false, outlineHex: "#000000",
        boxHex: "#E0641EF2", revealFuture: true, scaleActive: false, baseMaxWordsPerLine: 4, position: .bottom)

    // MARK: - Static preview (alpha)

    /// A small representative card image (transparent background) showing the style — two sample
    /// words, the second treated as the "active" word so highlights read at a glance.
    func previewImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        let fontSize = size.height * 0.34
        let font = self.font(size: fontSize)
        let words = ["Direct", "Actors"]
        let attrsBase = attributes(font: font, color: baseColor)
        let attrsActive = attributes(font: font, color: activeColor)

        // Measure.
        let gap: CGFloat = fontSize * 0.28
        let w0 = (words[0] as NSString).size(withAttributes: attrsBase)
        let w1 = (words[1] as NSString).size(withAttributes: attrsActive)
        let totalW = w0.width + gap + w1.width
        let boxPadX = fontSize * 0.5, boxPadY = fontSize * 0.32
        let contentH = max(w0.height, w1.height)
        var x = (size.width - totalW) / 2
        let y = (size.height - contentH) / 2

        // Background box.
        if let box = boxColor {
            let rect = CGRect(x: x - boxPadX, y: y - boxPadY, width: totalW + boxPadX * 2, height: contentH + boxPadY * 2)
            ctx.setFillColor(box.cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height * 0.28, cornerHeight: rect.height * 0.28, transform: nil))
            ctx.fillPath()
        }

        draw(words[0], at: CGPoint(x: x, y: y), font: font, color: baseColor)
        x += w0.width + gap
        draw(words[1], at: CGPoint(x: x, y: y), font: font, color: activeColor)
        return image
    }

    private func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if outline { a[.strokeColor] = outlineColor; a[.strokeWidth] = -6.0 }
        return a
    }
    private func draw(_ text: String, at p: CGPoint, font: NSFont, color: NSColor) {
        let s = uppercase ? text.uppercased() : text
        (s as NSString).draw(at: p, withAttributes: attributes(font: font, color: color))
    }
}

extension NSColor {
    /// Parse "#RGB", "#RRGGBB", or "#RRGGBBAA".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        switch s.count {
        case 6:
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255; a = 1
        case 8:
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255
        default: return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
