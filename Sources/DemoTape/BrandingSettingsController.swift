import AppKit

/// Full-screen overlay to place a logo/brand watermark on the recording. Upload a logo, drag
/// it anywhere (hand cursor), resize it with the top-right handle, then Confirm to save (or
/// Remove to clear). Mirrors the webcam settings editor. The watermark is baked into the export.
@available(macOS 12.3, *)
final class BrandingSettingsController: NSObject {
    private var panel: NSPanel?
    private var logo: LogoControl?
    private var statusLabel: NSTextField!
    private var removeButton: NSButton!
    private var content: NSView!
    private var card: NSView!
    private var onClose: (() -> Void)?
    private var imagePath = ""
    private var escMonitor: Any?

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
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dim.autoresizingMask = [.width, .height]
        content.addSubview(dim)

        // Controls card — dark translucent (see-through but readable), dashed border.
        let cardW: CGFloat = 480, cardH: CGFloat = 244
        card = NSView(frame: NSRect(x: content.bounds.midX - cardW / 2,
                                    y: content.bounds.midY - cardH / 2,
                                    width: cardW, height: cardH))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        let dashed = CAShapeLayer()
        dashed.path = CGPath(roundedRect: NSRect(x: 1, y: 1, width: cardW - 2, height: cardH - 2),
                             cornerWidth: 18, cornerHeight: 18, transform: nil)
        dashed.fillColor = NSColor.clear.cgColor
        dashed.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        dashed.lineWidth = 1.5
        dashed.lineDashPattern = [5, 4]
        card.layer?.addSublayer(dashed)

        let title = NSTextField(labelWithString: "Branding")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.frame = NSRect(x: 24, y: cardH - 50, width: cardW - 48, height: 30)
        card.addSubview(title)

        let help = NSTextField(wrappingLabelWithString:
            "Upload a logo, drag it anywhere, and resize it with the top-right handle. "
            + "Confirm to watermark your recordings; Remove to clear it.")
        help.font = .systemFont(ofSize: 13)
        help.textColor = NSColor.white.withAlphaComponent(0.75)
        help.alignment = .center
        help.frame = NSRect(x: 30, y: cardH - 108, width: cardW - 60, height: 44)
        card.addSubview(help)

        // Status ("no logo") lives inside the card so it's always readable.
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 20, y: 78, width: cardW - 40, height: 18)
        card.addSubview(statusLabel)

        let upload = makeButton("Upload Logo…", action: #selector(uploadLogo), accent: true)
        upload.frame = NSRect(x: 20, y: 24, width: 130, height: 40)
        card.addSubview(upload)
        removeButton = makeButton("Remove", action: #selector(removeLogo), accent: false)
        removeButton.frame = NSRect(x: 156, y: 24, width: 84, height: 40)
        card.addSubview(removeButton)
        let cancel = makeButton("Cancel", action: #selector(cancel), accent: false)
        cancel.frame = NSRect(x: 244, y: 24, width: 84, height: 40)
        card.addSubview(cancel)
        let confirm = makeButton("Confirm", action: #selector(confirm), accent: true)
        confirm.frame = NSRect(x: 334, y: 24, width: 126, height: 40)
        confirm.keyEquivalent = "\r"
        card.addSubview(confirm)

        content.addSubview(card)

        panel.contentView = content
        self.panel = panel

        loadExistingLogo()
        updateState()

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel != nil, event.keyCode == 53 else { return event }
            self.cancel(); return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func loadExistingLogo() {
        let path = Settings.brandingImagePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path) else { return }
        imagePath = path
        addLogo(image: image, centerX: CGFloat(Settings.brandingCenterX),
                centerY: CGFloat(Settings.brandingCenterY),
                widthFraction: CGFloat(Settings.brandingWidthFraction))
    }

    private func addLogo(image: NSImage, centerX: CGFloat, centerY: CGFloat, widthFraction: CGFloat) {
        logo?.removeFromSuperview()
        let sw = content.bounds.width
        let w = max(40, widthFraction * sw)
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let h = w / max(0.01, aspect)
        let cx = centerX * content.bounds.width
        let cy = content.bounds.height - centerY * content.bounds.height
        let control = LogoControl(image: image, frame: NSRect(x: cx - w/2, y: cy - h/2, width: w, height: h))
        control.aspect = aspect
        control.clampBounds = content.bounds
        control.maxWidth = content.bounds.width * 0.6
        content.addSubview(control, positioned: .below, relativeTo: card)
        logo = control
    }

    @objc private func uploadLogo() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        panel?.level = .normal                    // let the picker appear above the overlay
        let result = open.runModal()
        panel?.level = .screenSaver
        panel?.makeKeyAndOrderFront(nil)
        guard result == .OK, let url = open.url, let image = NSImage(contentsOf: url) else { return }
        imagePath = url.path
        addLogo(image: image, centerX: 0.86, centerY: 0.90, widthFraction: 0.14)
        updateState()
    }

    @objc private func removeLogo() {
        logo?.removeFromSuperview(); logo = nil
        imagePath = ""
        Settings.brandingImagePath = ""
        Settings.brandingEnabled = false
        close()
    }

    @objc private func cancel() { close() }

    @objc private func confirm() {
        if let logo = logo, !imagePath.isEmpty, let screen = NSScreen.main, let panel = panel {
            let center = CGPoint(x: logo.frame.midX, y: logo.frame.midY)
            let screenPt = panel.convertPoint(toScreen: center)
            let f = screen.frame
            Settings.brandingImagePath = imagePath
            Settings.brandingCenterX = Double(min(max((screenPt.x - f.minX) / f.width, 0), 1))
            Settings.brandingCenterY = Double(min(max(1 - (screenPt.y - f.minY) / f.height, 0), 1))
            Settings.brandingWidthFraction = Double(logo.frame.width / f.width)
            Settings.brandingEnabled = true
        }
        close()
    }

    private func updateState() {
        let has = logo != nil
        removeButton.isEnabled = has
        statusLabel.stringValue = has ? "Drag to position · resize from the top-right handle"
                                      : "No logo yet — click Upload Logo… to add one."
    }

    private func close() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        panel?.orderOut(nil); panel = nil; logo = nil
        onClose?(); onClose = nil
    }

    private func makeButton(_ title: String, action: Selector, accent: Bool) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        if accent { b.contentTintColor = .controlAccentColor }
        return b
    }
}

/// Logo you can drag (hand cursor) and resize from a top-right handle, keeping aspect ratio.
/// Cursors are driven from a tracking area since the overlay panel isn't key.
private final class LogoControl: NSView {
    let imageView = NSImageView()
    private let handleIcon = NSImageView()
    var clampBounds: CGRect = .zero
    var aspect: CGFloat = 1
    var minWidth: CGFloat = 40
    var maxWidth: CGFloat = 600

    private let handleSize: CGFloat = 26
    private var mode: Mode = .none
    private var dragStart = NSPoint.zero
    private var startFrame = NSRect.zero
    private var anchor = NSPoint.zero        // fixed bottom-left corner while resizing
    private var tracking: NSTrackingArea?
    private enum Mode { case none, move, resize }

    init(image: NSImage, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        handleIcon.image = Self.resizeIcon()
        handleIcon.contentTintColor = .white
        handleIcon.wantsLayer = true
        handleIcon.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        handleIcon.layer?.cornerRadius = handleSize / 2
        handleIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(handleIcon)
        layoutParts()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); layoutParts() }

    private func layoutParts() {
        imageView.frame = bounds
        handleIcon.frame = NSRect(x: bounds.maxX - handleSize, y: bounds.maxY - handleSize,
                                  width: handleSize, height: handleSize)
    }

    private func handleRect() -> NSRect {
        NSRect(x: bounds.maxX - handleSize - 4, y: bounds.maxY - handleSize - 4,
               width: handleSize + 8, height: handleSize + 8)
    }

    // MARK: - Cursor (tracking-area driven)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if handleRect().contains(p) { Self.resizeCursor().set() } else { NSCursor.openHand.set() }
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    // MARK: - Drag / resize

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mode = handleRect().contains(p) ? .resize : .move
        dragStart = event.locationInWindow
        startFrame = frame
        anchor = frame.origin                 // bottom-left stays put while resizing
        if mode == .move { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        switch mode {
        case .move:
            let now = event.locationInWindow
            let dx = now.x - dragStart.x, dy = now.y - dragStart.y
            var o = NSPoint(x: startFrame.origin.x + dx, y: startFrame.origin.y + dy)
            if !clampBounds.isEmpty {
                o.x = min(max(o.x, clampBounds.minX), clampBounds.maxX - frame.width)
                o.y = min(max(o.y, clampBounds.minY), clampBounds.maxY - frame.height)
            }
            setFrameOrigin(o)
        case .resize:
            // Pin the bottom-left corner; the top-right corner follows the cursor (linear),
            // keeping aspect ratio and clamping to the screen.
            guard let sv = superview else { break }
            let m = sv.convert(event.locationInWindow, from: nil)
            var w = min(max(m.x - anchor.x, minWidth), maxWidth)
            if !clampBounds.isEmpty { w = min(w, clampBounds.maxX - anchor.x) }
            var h = w / max(0.01, aspect)
            if !clampBounds.isEmpty, anchor.y + h > clampBounds.maxY {
                h = clampBounds.maxY - anchor.y
                w = h * aspect
            }
            frame = NSRect(x: anchor.x, y: anchor.y, width: w, height: h)
            layoutParts()
            Self.resizeCursor().set()
        case .none: break
        }
    }
    override func mouseUp(with event: NSEvent) { mode = .none; NSCursor.openHand.set() }

    // MARK: - Icons / cursors

    private static func resizeCursor() -> NSCursor {
        let sel = NSSelectorFromString("_windowResizeNorthEastSouthWestCursor")
        if NSCursor.responds(to: sel), let c = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return c
        }
        return .crosshair
    }

    /// Diagonal resize glyph, flipped to the NE–SW orientation (top-right handle).
    private static func resizeIcon() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        guard let base = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                                 accessibilityDescription: "Resize")?.withSymbolConfiguration(cfg)
        else { return nil }
        let flipped = NSImage(size: base.size)
        flipped.lockFocus()
        let t = NSAffineTransform()
        t.translateX(by: base.size.width, yBy: 0); t.scaleX(by: -1, yBy: 1); t.concat()
        base.draw(at: .zero, from: NSRect(origin: .zero, size: base.size), operation: .sourceOver, fraction: 1)
        flipped.unlockFocus()
        flipped.isTemplate = true
        return flipped
    }
}
