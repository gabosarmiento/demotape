import AppKit

/// DemoTape's visual theme: a warm "tape shell" palette that follows the system light/dark setting,
/// with the logo's six-colour stripe used sparingly as the brand signature and a purple accent
/// (the stripe's magenta) for interactive controls.
///
/// Colours are **dynamic** `NSColor`s — they resolve to the light or dark variant based on the
/// drawing context's appearance, so labels and custom-drawn views adapt automatically when the user
/// flips the system theme, with no observers.
@available(macOS 12.3, *)
enum Theme {

    // MARK: - Dynamic colours (paper ⇄ dark)

    private static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
    }

    /// Accent = the logo stripe's magenta/purple. Darker on light paper for punch + legibility;
    /// a touch lighter in dark mode for contrast on the near-black shell.
    static let accent      = dyn(rgb(0x83, 0x2B, 0x72), rgb(0xC8, 0x63, 0xB4))
    static let accentInk   = NSColor.white
    /// The record action stays red in both themes.
    static let recordRed   = rgb(0xDC, 0x50, 0x50)

    static let ink         = dyn(rgb(0x21, 0x1E, 0x17), rgb(0xEF, 0xE7, 0xD4))
    static let dim         = dyn(rgb(0x6E, 0x66, 0x56), rgb(0xB3, 0xA8, 0x91))
    static let faint       = dyn(rgb(0x9A, 0x92, 0x80), rgb(0x7C, 0x73, 0x61))

    static let canvasTop   = dyn(rgb(0xEE, 0xE8, 0xD8), rgb(0x1C, 0x16, 0x0E))
    static let canvasBottom = dyn(rgb(0xE3, 0xDB, 0xC6), rgb(0x14, 0x10, 0x09))
    /// Flat warm window background for the settings/utility dialogs.
    static let windowBackground = dyn(rgb(0xEA, 0xE3, 0xD2), rgb(0x1A, 0x15, 0x0E))
    static let card        = dyn(rgb(0xF6, 0xF1, 0xE4), rgb(0x23, 0x1C, 0x12))
    static let stroke      = dyn(rgb(0x21, 0x1E, 0x17, 0.12), rgb(0xF0, 0xE1, 0xC8, 0.12))
    static let strokeStrong = dyn(rgb(0x21, 0x1E, 0x17, 0.22), rgb(0xF0, 0xE1, 0xC8, 0.22))

    // MARK: - Logo stripe (fixed in both themes)

    static let stripeColors: [NSColor] = [
        rgb(0xF0, 0xA0, 0x3C), rgb(0xF0, 0x78, 0x3C), rgb(0xDC, 0x50, 0x50),
        rgb(0xA0, 0x3C, 0x8C), rgb(0x64, 0x64, 0xA0), rgb(0x3C, 0x8C, 0xC8),
    ]

    /// A thin horizontal stripe image (the brand signature rule / slider band). Colours are fixed,
    /// so one image works in both appearances.
    static func stripeImage(width: CGFloat, height: CGFloat, radius: CGFloat = 2) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                                xRadius: radius, yRadius: radius)
        path.addClip()
        let seg = width / CGFloat(stripeColors.count)
        for (i, c) in stripeColors.enumerated() {
            c.setFill()
            NSRect(x: CGFloat(i) * seg, y: 0, width: ceil(seg) + 1, height: height).fill()
        }
        img.unlockFocus()
        return img
    }

    /// The compact rainbow "chip" used as the brand mark in title areas and the control bar.
    static func brandMark(width: CGFloat = 20, height: CGFloat = 12) -> NSImage {
        stripeImage(width: width, height: height, radius: 2)
    }

    // MARK: - Control helpers

    /// A filled, rounded primary button in the accent colour with white title.
    static func primaryButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        stylePrimary(b)
        return b
    }

    /// Recolour an existing button as the accent primary (white title on purple).
    static func stylePrimary(_ b: NSButton) {
        b.bezelColor = accent
        b.contentTintColor = accentInk
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .foregroundColor: accentInk,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
    }

    /// Give a window the warm themed background so every surface follows the same palette
    /// (content views are transparent, so the window colour shows through). Follows light/dark.
    static func style(_ window: NSWindow) {
        window.backgroundColor = windowBackground
    }
}

/// A view that paints the themed canvas (a subtle warm vertical gradient) and repaints when the
/// system appearance changes, so a window's background follows light/dark automatically.
@available(macOS 12.3, *)
final class ThemedBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let g = NSGradient(colors: [Theme.canvasTop, Theme.canvasBottom])
        g?.draw(in: bounds, angle: -90)
    }
}

/// A flat themed "card" surface (fills `Theme.card`), following light/dark automatically. Used as
/// the popover body so it reads as the warm tape card rather than system grey.
@available(macOS 12.3, *)
final class ThemedCardView: NSView {
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) { Theme.card.setFill(); dirtyRect.fill() }
}
