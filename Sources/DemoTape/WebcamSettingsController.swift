import AppKit
import AVFoundation

/// Full-screen overlay for positioning the webcam. The screen is blurred, a big
/// Confirm button and instruction sit centered (always reachable), and a live webcam
/// circle can be dragged anywhere, resized via a top-right handle, and zoomed with a
/// slider inside the circle. Confirm saves position, size, and zoom to Settings.
@available(macOS 12.3, *)
final class WebcamSettingsController: NSObject {
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var circle: CircleControl?

    func show() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: present()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.present() : self.presentDenied() }
            }
        default: presentDenied()
        }
    }

    private func presentDenied() {
        let alert = NSAlert()
        alert.messageText = "Camera access needed"
        alert.informativeText = "Enable DemoTape under System Preferences → Security & Privacy → Privacy → Camera."
        alert.runModal()
    }

    private func present() {
        guard panel == nil, let screen = NSScreen.main,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        session.startRunning()

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

        // Translucent dark backdrop — the screen stays visible underneath, just dimmed.
        let dim = NSView(frame: content.bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dim.autoresizingMask = [.width, .height]
        content.addSubview(dim)

        // Webcam circle (draggable + resizable + zoom).
        let d = CGFloat(Settings.webcamSize) * screen.frame.width
        let minD = 0.14 * screen.frame.width
        let maxD = 0.34 * screen.frame.width
        let cx = CGFloat(Settings.webcamPositionX) * content.bounds.width
        let cyTop = CGFloat(Settings.webcamPositionY) * content.bounds.height
        let cy = content.bounds.height - cyTop
        let circle = CircleControl(preview: preview, diameter: d, minDiameter: minD,
                                   maxDiameter: maxD, zoom: CGFloat(Settings.webcamZoom))
        circle.frame = NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        circle.clampBounds = content.bounds
        circle.layoutContents()
        content.addSubview(circle)

        // Centered frosted instruction card with a Confirm button (independent of the circle).
        let cardW: CGFloat = 460, cardH: CGFloat = 210
        let card = NSView(frame: NSRect(x: content.bounds.midX - cardW / 2,
                                        y: content.bounds.midY - cardH / 2,
                                        width: cardW, height: cardH))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.clear.cgColor
        // Dotted rounded border, no fill.
        let dashed = CAShapeLayer()
        dashed.path = CGPath(roundedRect: NSRect(x: 1, y: 1, width: cardW - 2, height: cardH - 2),
                             cornerWidth: 18, cornerHeight: 18, transform: nil)
        dashed.fillColor = NSColor.clear.cgColor
        dashed.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        dashed.lineWidth = 1.5
        dashed.lineDashPattern = [5, 4]
        card.layer?.addSublayer(dashed)

        let title = NSTextField(labelWithString: "Position the camera")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.frame = NSRect(x: 24, y: cardH - 58, width: cardW - 48, height: 30)
        card.addSubview(title)

        let help = NSTextField(wrappingLabelWithString:
            "Drag the circle to reposition it. Use the corner handle to resize and the slider to zoom in. Click Save Position to store your webcam layout.")
        help.font = .systemFont(ofSize: 13)
        help.textColor = NSColor.white.withAlphaComponent(0.72)
        help.alignment = .center
        help.frame = NSRect(x: 30, y: 78, width: cardW - 60, height: 58)
        card.addSubview(help)

        let confirm = HoverButton(frame: NSRect(x: cardW / 2 - 95, y: 24, width: 190, height: 40))
        confirm.target = self
        confirm.action = #selector(self.confirm)
        confirm.keyEquivalent = "\r"
        card.addSubview(confirm)

        content.addSubview(card)

        panel.contentView = content
        self.panel = panel
        self.session = session
        self.circle = circle

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func confirm() {
        if let panel = panel, let circle = circle, let screen = NSScreen.main {
            let centerInContent = CGPoint(x: circle.frame.midX, y: circle.frame.midY)
            let screenPt = panel.convertPoint(toScreen: centerInContent)
            let f = screen.frame
            let nx = (screenPt.x - f.minX) / f.width
            let nyBottom = (screenPt.y - f.minY) / f.height
            Settings.webcamPositionX = Double(min(max(nx, 0), 1))
            Settings.webcamPositionY = Double(min(max(1 - nyBottom, 0), 1))
            Settings.webcamZoom = Double(circle.zoom)
            Settings.webcamSize = Double(circle.frame.width / f.width)
        }
        close()
    }

    private func close() {
        session?.stopRunning()
        session = nil
        panel?.orderOut(nil)
        panel = nil
        circle = nil
    }
}

// MARK: - Circle control (drag, resize, in-circle zoom)

@available(macOS 12.3, *)
private final class CircleControl: NSView {
    private let circleLayer = CALayer()
    private let preview: AVCaptureVideoPreviewLayer
    private let slider = NSSlider()
    private let magnifier = NSImageView()
    private let handle = ResizeHandle(frame: .zero)

    let minDiameter: CGFloat
    let maxDiameter: CGFloat
    var clampBounds: CGRect = .zero
    var zoom: CGFloat { CGFloat(slider.doubleValue) }

    private var dragStart: NSPoint = .zero
    private var startOrigin: NSPoint = .zero

    init(preview: AVCaptureVideoPreviewLayer, diameter: CGFloat,
         minDiameter: CGFloat, maxDiameter: CGFloat, zoom: CGFloat) {
        self.preview = preview
        self.minDiameter = minDiameter
        self.maxDiameter = maxDiameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        circleLayer.masksToBounds = true
        circleLayer.borderWidth = 3
        circleLayer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        circleLayer.addSublayer(preview)
        layer?.addSublayer(circleLayer)

        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Zoom")
        magnifier.contentTintColor = .white
        magnifier.imageScaling = .scaleProportionallyUpOrDown
        addSubview(magnifier)

        slider.minValue = 1.0
        slider.maxValue = 3.0
        slider.doubleValue = Double(max(1, zoom))
        slider.target = self
        slider.action = #selector(zoomChanged)
        addSubview(slider)

        handle.onResize = { [weak self] delta in self?.resize(by: delta) }
        addSubview(handle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func layoutContents() {
        let size = bounds.width
        // Disable implicit animations so the corner radius never lags behind the frame
        // (which briefly showed square corners while resizing).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circleLayer.frame = bounds
        circleLayer.cornerRadius = size / 2
        preview.frame = circleLayer.bounds
        applyPreviewTransform()
        CATransaction.commit()

        // Zoom slider (full width) with the magnifier icon centered underneath it.
        let sh: CGFloat = 28
        let sw = size * 0.6
        let sliderY = size * 0.2
        slider.frame = NSRect(x: (size - sw) / 2, y: sliderY, width: sw, height: sh)
        let iconSize: CGFloat = 16
        magnifier.frame = NSRect(x: (size - iconSize) / 2, y: sliderY - iconSize - 6,
                                 width: iconSize, height: iconSize)

        let hs: CGFloat = 30
        // Top-right, sitting on the circle edge (~45°).
        let hx = size / 2 + (size / 2) * 0.707 - hs / 2
        let hy = size / 2 + (size / 2) * 0.707 - hs / 2
        handle.frame = NSRect(x: hx, y: hy, width: hs, height: hs)
    }

    private func applyPreviewTransform() {
        preview.setAffineTransform(CGAffineTransform(scaleX: -zoom, y: zoom)) // mirror + zoom
    }

    @objc private func zoomChanged() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        applyPreviewTransform()
        CATransaction.commit()
    }

    private func resize(by delta: CGFloat) {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        let d = min(max(frame.width + delta, minDiameter), maxDiameter)
        frame = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        layoutContents()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        startOrigin = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        let now = event.locationInWindow
        var origin = NSPoint(x: startOrigin.x + (now.x - dragStart.x),
                             y: startOrigin.y + (now.y - dragStart.y))
        if !clampBounds.isEmpty {
            origin.x = min(max(origin.x, clampBounds.minX), clampBounds.maxX - frame.width)
            origin.y = min(max(origin.y, clampBounds.minY), clampBounds.maxY - frame.height)
        }
        setFrameOrigin(origin)
    }
}

/// Resize knob showing the diagonal double-arrow icon.
private final class ResizeHandle: NSView {
    var onResize: ((CGFloat) -> Void)?
    private var startMouse: NSPoint = .zero
    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        // The top-right↔bottom-left variant doesn't exist on macOS 12, so flip the
        // available top-left↔bottom-right symbol horizontally.
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        if let base = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                              accessibilityDescription: "Resize")?.withSymbolConfiguration(cfg) {
            icon.image = ResizeHandle.flippedHorizontally(base)
        }
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Returns a horizontally mirrored, still-tintable (template) copy of the image.
    static func flippedHorizontally(_ image: NSImage) -> NSImage {
        let flipped = NSImage(size: image.size)
        flipped.lockFocus()
        let t = NSAffineTransform()
        t.translateX(by: image.size.width, yBy: 0)
        t.scaleX(by: -1, yBy: 1)
        t.concat()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1)
        flipped.unlockFocus()
        flipped.isTemplate = true
        return flipped
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        icon.frame = bounds.insetBy(dx: 6, dy: 6)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) { startMouse = NSEvent.mouseLocation }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        // Up/right increases size (handle is at the top-right).
        let delta = (now.x - startMouse.x) + (now.y - startMouse.y)
        startMouse = now
        onResize?(delta)
    }
}

/// A modern accent-filled button with hover feedback and a pointing-hand cursor.
private final class HoverButton: NSButton {
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        setBackground(base: true)
        setTitleText("Save Position")
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setTitleText(_ text: String) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .paragraphStyle: p
        ])
    }

    private func setBackground(base: Bool) {
        let accent = NSColor.controlAccentColor
        let color = base ? accent : (accent.blended(withFraction: 0.18, of: .white) ?? accent)
        layer?.backgroundColor = color.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        setBackground(base: false)
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        setBackground(base: true)
        NSCursor.arrow.set()
    }
}
