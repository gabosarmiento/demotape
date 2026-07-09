import AppKit

/// Full-screen overlay to place a logo/brand watermark on the recording. Upload a logo,
/// drag it anywhere, size it with a slider, then Confirm to save (or Remove to clear it).
/// Mirrors the webcam settings editor. The watermark is baked into the styled export.
@available(macOS 12.3, *)
final class BrandingSettingsController: NSObject {
    private var panel: NSPanel?
    private var logoView: DraggableImageView?
    private var sizeSlider: NSSlider!
    private var removeButton: NSButton!
    private var statusLabel: NSTextField!
    private var content: NSView!
    private var card: NSView!

    private var onClose: (() -> Void)?

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        guard panel == nil, let screen = NSScreen.main else { onClose(); return }

        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        self.content = content

        let dim = NSView(frame: content.bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dim.autoresizingMask = [.width, .height]
        content.addSubview(dim)

        // Centered card with title, help, size slider, and buttons.
        let cardW: CGFloat = 480, cardH: CGFloat = 250
        card = NSView(frame: NSRect(x: content.bounds.midX - cardW / 2,
                                    y: content.bounds.midY - cardH / 2,
                                    width: cardW, height: cardH))
        card.wantsLayer = true
        let dashed = CAShapeLayer()
        dashed.path = CGPath(roundedRect: NSRect(x: 1, y: 1, width: cardW - 2, height: cardH - 2),
                             cornerWidth: 18, cornerHeight: 18, transform: nil)
        dashed.fillColor = NSColor.clear.cgColor
        dashed.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        dashed.lineWidth = 1.5
        dashed.lineDashPattern = [5, 4]
        card.layer?.addSublayer(dashed)

        let title = NSTextField(labelWithString: "Branding")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.frame = NSRect(x: 24, y: cardH - 54, width: cardW - 48, height: 30)
        card.addSubview(title)

        let help = NSTextField(wrappingLabelWithString:
            "Upload a logo, drag it anywhere on screen, and size it with the slider. "
            + "Confirm to watermark your recordings; Remove to clear it.")
        help.font = .systemFont(ofSize: 13)
        help.textColor = NSColor.white.withAlphaComponent(0.72)
        help.alignment = .center
        help.frame = NSRect(x: 30, y: cardH - 108, width: cardW - 60, height: 44)
        card.addSubview(help)

        let sizeLabel = NSTextField(labelWithString: "Size")
        sizeLabel.font = .systemFont(ofSize: 12)
        sizeLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        sizeLabel.frame = NSRect(x: 40, y: 104, width: 40, height: 18)
        card.addSubview(sizeLabel)
        sizeSlider = NSSlider(value: Settings.brandingWidthFraction, minValue: 0.05, maxValue: 0.4,
                              target: self, action: #selector(sizeChanged))
        sizeSlider.frame = NSRect(x: 80, y: 102, width: cardW - 120, height: 22)
        card.addSubview(sizeSlider)

        let upload = makeButton("Upload Logo…", action: #selector(uploadLogo), accent: true)
        upload.frame = NSRect(x: cardW / 2 - 200, y: 30, width: 150, height: 40)
        card.addSubview(upload)
        removeButton = makeButton("Remove", action: #selector(removeLogo), accent: false)
        removeButton.frame = NSRect(x: cardW / 2 - 40, y: 30, width: 100, height: 40)
        card.addSubview(removeButton)
        let confirm = makeButton("Confirm", action: #selector(confirm), accent: true)
        confirm.frame = NSRect(x: cardW / 2 + 70, y: 30, width: 130, height: 40)
        confirm.keyEquivalent = "\r"
        card.addSubview(confirm)

        content.addSubview(card)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: content.bounds.midX - 200, y: card.frame.maxY + 12, width: 400, height: 18)
        content.addSubview(statusLabel)

        panel.contentView = content
        self.panel = panel

        loadExistingLogo()
        updateState()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func loadExistingLogo() {
        let path = Settings.brandingImagePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path) else { return }
        addLogoView(image: image,
                    centerX: CGFloat(Settings.brandingCenterX),
                    centerY: CGFloat(Settings.brandingCenterY),
                    widthFraction: CGFloat(Settings.brandingWidthFraction))
    }

    private func addLogoView(image: NSImage, centerX: CGFloat, centerY: CGFloat, widthFraction: CGFloat) {
        logoView?.removeFromSuperview()
        let sw = content.bounds.width
        let w = max(20, widthFraction * sw)
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let h = w / max(0.01, aspect)
        let cx = centerX * content.bounds.width
        let cyTop = centerY * content.bounds.height
        let cy = content.bounds.height - cyTop
        let v = DraggableImageView(frame: NSRect(x: cx - w/2, y: cy - h/2, width: w, height: h))
        v.image = image
        v.imageScaling = .scaleProportionallyUpOrDown
        v.clampBounds = content.bounds
        v.aspect = aspect
        content.addSubview(v)
        content.addSubview(card)   // keep the controls card on top of the logo
        logoView = v
    }

    @objc private func sizeChanged() {
        guard let v = logoView else { return }
        let w = max(20, CGFloat(sizeSlider.doubleValue) * content.bounds.width)
        let h = w / max(0.01, v.aspect)
        let c = CGPoint(x: v.frame.midX, y: v.frame.midY)
        v.frame = NSRect(x: c.x - w/2, y: c.y - h/2, width: w, height: h)
    }

    @objc private func uploadLogo() {
        let panelOpen = NSOpenPanel()
        panelOpen.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        panelOpen.allowsMultipleSelection = false
        panelOpen.canChooseDirectories = false
        guard panelOpen.runModal() == .OK, let url = panelOpen.url,
              let image = NSImage(contentsOf: url) else { return }
        Settings.brandingImagePath = url.path
        let frac = CGFloat(sizeSlider.doubleValue)
        addLogoView(image: image, centerX: 0.86, centerY: 0.90, widthFraction: frac)
        updateState()
    }

    @objc private func removeLogo() {
        logoView?.removeFromSuperview(); logoView = nil
        Settings.brandingImagePath = ""
        Settings.brandingEnabled = false
        updateState()
        close()
    }

    @objc private func confirm() {
        if let v = logoView, let screen = NSScreen.main, let panel = panel {
            let center = CGPoint(x: v.frame.midX, y: v.frame.midY)
            let screenPt = panel.convertPoint(toScreen: center)
            let f = screen.frame
            Settings.brandingCenterX = Double(min(max((screenPt.x - f.minX) / f.width, 0), 1))
            Settings.brandingCenterY = Double(min(max(1 - (screenPt.y - f.minY) / f.height, 0), 1))
            Settings.brandingWidthFraction = sizeSlider.doubleValue
            Settings.brandingEnabled = true
        }
        close()
    }

    private func updateState() {
        let has = logoView != nil
        removeButton.isEnabled = has
        statusLabel.stringValue = has ? "" : "No logo yet — click Upload Logo… to add one."
    }

    private func close() {
        panel?.orderOut(nil); panel = nil; logoView = nil
        onClose?(); onClose = nil
    }

    private func makeButton(_ title: String, action: Selector, accent: Bool) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.wantsLayer = true
        if accent { b.contentTintColor = .controlAccentColor }
        return b
    }
}

/// An image view you can drag anywhere within its parent bounds.
private final class DraggableImageView: NSImageView {
    var clampBounds: CGRect = .zero
    var aspect: CGFloat = 1
    private var dragStart: NSPoint = .zero
    private var startOrigin: NSPoint = .zero

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow; startOrigin = frame.origin
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        let now = event.locationInWindow
        var o = NSPoint(x: startOrigin.x + (now.x - dragStart.x),
                        y: startOrigin.y + (now.y - dragStart.y))
        if !clampBounds.isEmpty {
            o.x = min(max(o.x, clampBounds.minX), clampBounds.maxX - frame.width)
            o.y = min(max(o.y, clampBounds.minY), clampBounds.maxY - frame.height)
        }
        setFrameOrigin(o)
    }
    override func mouseUp(with event: NSEvent) { NSCursor.openHand.set() }
}
