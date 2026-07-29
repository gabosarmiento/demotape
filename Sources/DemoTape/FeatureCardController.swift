import AppKit

/// A reusable one-time explainer card, in the same spirit as the welcome screen: a title, one
/// concise line, optional shape/symbol cells, and a "Don't show this again" control. Shown the
/// first time a feature is used so it can explain itself in place, then never nags again.
@available(macOS 12.3, *)
final class FeatureCardController: NSObject, NSWindowDelegate {

    /// A small illustrative cell: an image (SF Symbol or shape glyph) over a short caption.
    struct Cell { let image: NSImage?; let caption: String }

    private var window: NSWindow?
    private var dontShowAgain: NSButton!
    private var dismissKey = ""
    private let w: CGFloat = 480
    private let leftX: CGFloat = 32

    func show(title: String, heading: String, body: String, cells: [Cell], dismissKey: String) {
        self.dismissKey = dismissKey
        let hasCells = !cells.isEmpty
        let h: CGFloat = hasCells ? 300 : 220

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = title
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
        // One continuous card: let the themed background run under a transparent title bar instead of
        // a system-grey bar seaming it in two.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.styleMask.insert(.fullSizeContentView)
        win.isMovableByWindowBackground = true
        let content = ThemedBackgroundView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Brand mark (small rainbow chip) top-left.
        let mark = NSImageView(frame: NSRect(x: leftX, y: h - 44, width: 22, height: 13))
        mark.image = Theme.brandMark(width: 22, height: 13)
        mark.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(mark)

        let head = NSTextField(labelWithString: heading)
        head.font = .systemFont(ofSize: 20, weight: .bold)
        head.textColor = Theme.ink
        head.frame = NSRect(x: leftX, y: h - 74, width: w - leftX * 2, height: 26)
        content.addSubview(head)

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = Theme.dim
        bodyLabel.frame = NSRect(x: leftX, y: h - 138, width: w - leftX * 2, height: 54)
        content.addSubview(bodyLabel)

        if hasCells {
            let cellW = (w - leftX * 2) / CGFloat(cells.count)
            for (i, c) in cells.enumerated() {
                addCell(c, x: leftX + CGFloat(i) * cellW, width: cellW, y: h - 214, on: content)
            }
        }

        dontShowAgain = NSButton(checkboxWithTitle: "Don't show this again", target: nil, action: nil)
        dontShowAgain.state = .on
        dontShowAgain.attributedTitle = NSAttributedString(string: "Don't show this again", attributes: [
            .foregroundColor: Theme.ink, .font: NSFont.systemFont(ofSize: 12),
        ])
        dontShowAgain.frame = NSRect(x: leftX, y: 26, width: 220, height: 20)
        content.addSubview(dontShowAgain)

        let gotIt = Theme.primaryButton("Got it", target: self, action: #selector(close))
        gotIt.keyEquivalent = "\r"
        gotIt.frame = NSRect(x: w - leftX - 120, y: 20, width: 120, height: 32)
        content.addSubview(gotIt)

        win.contentView = content
        self.window = win
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func addCell(_ cell: Cell, x: CGFloat, width: CGFloat, y: CGFloat, on view: NSView) {
        let iv = NSImageView(frame: NSRect(x: x + (width - 40) / 2, y: y + 30, width: 40, height: 40))
        iv.image = cell.image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.contentTintColor = Theme.accent   // tints template symbols; ignored by colored glyphs
        view.addSubview(iv)
        let label = NSTextField(wrappingLabelWithString: cell.caption)
        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.dim
        label.alignment = .center
        label.frame = NSRect(x: x, y: y - 6, width: width, height: 34)
        view.addSubview(label)
    }

    /// A tinted SF Symbol cell image.
    static func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    @objc private func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        if dontShowAgain.state == .on { Settings.dismissHelp(dismissKey) }
        window = nil
    }
}
