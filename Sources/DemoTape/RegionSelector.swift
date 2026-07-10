import AppKit

/// Full-screen overlay to drag-select a recording area. Dims the screen, shows the live
/// selection rectangle with dimensions, and a row of aspect-ratio **presets** below the hint.
/// Picking a preset locks the drag to that shape; the region (normalized, top-left) is saved
/// on release. Press Escape to cancel.
@available(macOS 12.3, *)
final class RegionSelector: NSObject {
    private var panel: NSPanel?
    private var onDone: ((Bool) -> Void)?
    private var escMonitor: Any?
    private weak var selectionView: SelectionView?
    private var chips: [NSButton] = []

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
        // Restore the last preset's aspect lock.
        let current = AreaPreset.named(Settings.regionPreset)
        view.activeAspect = current.aspect
        panel.contentView = view
        self.selectionView = view

        addControls(to: view, selected: current.name)

        self.panel = panel
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.panel != nil, e.keyCode == 53 else { return e }
            self.finish(rect: nil, screenSize: .zero)
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    /// A centered dark card holding the hint, "or pick a size", and the aspect-preset chips —
    /// so the text and icons stay readable over whatever's on screen behind them.
    private func addControls(to view: SelectionView, selected: String) {
        chips.removeAll()
        let presets = AreaPreset.all
        let chipW: CGFloat = 74, chipH: CGFloat = 62, gap: CGFloat = 8
        let totalW = CGFloat(presets.count) * chipW + CGFloat(presets.count - 1) * gap
        let cardW = max(totalW + 48, 480), cardH: CGFloat = 178

        let card = NSView(frame: NSRect(x: view.bounds.midX - cardW / 2,
                                        y: view.bounds.midY - cardH / 2, width: cardW, height: cardH))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        view.addSubview(card)
        view.controlsCard = card

        let hint = NSTextField(labelWithString: "Drag to select an area    ·    Esc to cancel")
        hint.font = .systemFont(ofSize: 17, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.frame = NSRect(x: 12, y: cardH - 46, width: cardW - 24, height: 24)
        card.addSubview(hint)

        let sub = NSTextField(labelWithString: "or pick a size")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = NSColor.white.withAlphaComponent(0.7)
        sub.alignment = .center
        sub.frame = NSRect(x: 12, y: cardH - 72, width: cardW - 24, height: 16)
        card.addSubview(sub)

        let startX = (cardW - totalW) / 2
        for (i, preset) in presets.enumerated() {
            let b = NSButton(frame: NSRect(x: startX + CGFloat(i) * (chipW + gap), y: 16, width: chipW, height: chipH))
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.imagePosition = .imageAbove
            b.image = preset.icon(color: .white)
            b.tag = i
            b.toolTip = preset.name
            b.attributedTitle = NSAttributedString(string: preset.short, attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .medium)
            ])
            b.wantsLayer = true
            b.layer?.cornerRadius = 8
            b.target = self
            b.action = #selector(pickPreset(_:))
            card.addSubview(b)
            chips.append(b)
        }
        highlight(selectedName: selected)
    }

    @objc private func pickPreset(_ sender: NSButton) {
        let preset = AreaPreset.all[sender.tag]
        Settings.regionPreset = preset.name
        highlight(selectedName: preset.name)

        guard let aspect = preset.aspect, let screen = NSScreen.main else {
            // Freeform: unlock and let the user drag their own area.
            selectionView?.activeAspect = nil
            selectionView?.needsDisplay = true
            return
        }
        // Drop a centered, optimally-sized area for this aspect; the user can adjust it
        // afterward with the frame handles.
        let f = screen.frame
        let maxW = f.width * 0.7, maxH = f.height * 0.7
        var w = maxW, h = maxW / aspect
        if h > maxH { h = maxH; w = maxH * aspect }
        let rect = CGRect(x: (f.width - w) / 2, y: (f.height - h) / 2, width: w, height: h)
        finish(rect: rect, screenSize: f.size)
    }

    private func highlight(selectedName: String) {
        for (i, chip) in chips.enumerated() {
            let on = AreaPreset.all[i].name == selectedName
            chip.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
                                             : NSColor.white.withAlphaComponent(0.10).cgColor
        }
    }

    private func finish(rect: CGRect?, screenSize: CGSize) {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let rect = rect, rect.width > 20, rect.height > 20, screenSize.width > 0 {
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
    var activeAspect: CGFloat?   // when set, the selection is locked to this width/height ratio
    weak var controlsCard: NSView?

    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        controlsCard?.isHidden = true   // get the card out of the way while dragging
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let rect = selectionRect(), rect.width > 20, rect.height > 20 { onFinish?(rect) } else { onCancel?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }

    private func selectionRect() -> CGRect? {
        guard let s = start, let c = current else { return nil }
        var w = abs(s.x - c.x), h = abs(s.y - c.y)
        if let a = activeAspect, w > 0, h > 0 {
            // Snap to the aspect ratio using the dominant drag dimension.
            if w / h > a { w = h * a } else { h = w / a }
        }
        let x = (c.x >= s.x) ? s.x : s.x - w
        let y = (c.y >= s.y) ? s.y : s.y - h
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        // The hint + presets live on a dark card (subviews); nothing to draw until dragging.
        guard let rect = selectionRect() else { return }

        NSColor.clear.set()
        let hole = NSBezierPath(rect: rect)
        hole.setClip()
        NSGraphicsContext.current?.compositingOperation = .clear
        rect.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

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
