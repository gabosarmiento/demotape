import AppKit

/// Full-screen overlay to drag-select a recording area. Dims the screen, shows the
/// live selection rectangle with dimensions, and saves the region (normalized to the
/// display, top-left origin) on release. Press Escape to cancel.
@available(macOS 12.3, *)
final class RegionSelector: NSObject {
    private var panel: NSPanel?
    private var onDone: ((Bool) -> Void)?

    func selectArea(completion: @escaping (Bool) -> Void) {
        guard panel == nil, let screen = NSScreen.main else { completion(false); return }
        onDone = completion

        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in self?.finish(rect: rect, screenSize: screen.frame.size) }
        view.onCancel = { [weak self] in self?.finish(rect: nil, screenSize: .zero) }
        panel.contentView = view

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    private func finish(rect: CGRect?, screenSize: CGSize) {
        if let rect = rect, rect.width > 20, rect.height > 20, screenSize.width > 0 {
            // View coords are bottom-left; convert to top-left normalized for storage.
            let nx = rect.minX / screenSize.width
            let nw = rect.width / screenSize.width
            let nh = rect.height / screenSize.height
            let nyTop = (screenSize.height - rect.maxY) / screenSize.height
            Settings.regionX = Double(nx)
            Settings.regionY = Double(nyTop)
            Settings.regionW = Double(nw)
            Settings.regionH = Double(nh)
            Settings.useRegion = true
            panel?.orderOut(nil); panel = nil
            onDone?(true)
        } else {
            panel?.orderOut(nil); panel = nil
            onDone?(false)
        }
        onDone = nil
    }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let rect = selectionRect() { onFinish?(rect) } else { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
    }

    private func selectionRect() -> CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        guard let rect = selectionRect() else {
            let hint = "Drag to select an area  ·  Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85)
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY),
                      withAttributes: attrs)
            return
        }

        // Punch a clear hole for the selection.
        NSColor.clear.set()
        let hole = NSBezierPath(rect: rect)
        hole.setClip()
        NSGraphicsContext.current?.compositingOperation = .clear
        rect.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        // Reset clip and draw the border + size label.
        NSBezierPath(rect: bounds).setClip()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect); border.lineWidth = 2; border.stroke()

        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        label.draw(at: NSPoint(x: rect.minX + 6, y: rect.maxY + 6), withAttributes: attrs)
    }
}
