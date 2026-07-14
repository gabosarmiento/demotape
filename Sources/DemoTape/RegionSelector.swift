import AppKit

/// Full-screen overlay to choose a recording area. Dims the screen and shows a bottom control bar
/// with two rows of presets: general aspect ratios and social-platform presets. Picking a preset
/// smoothly morphs a live preview frame (Mac-style expand/contract); press Return or click the
/// frame to start, or just drag anywhere to draw a custom area. Escape cancels.
@available(macOS 12.3, *)
final class RegionSelector: NSObject {
    private var panel: NSPanel?
    private var onDone: ((Bool) -> Void)?
    private var escMonitor: Any?
    private weak var selectionView: SelectionView?
    private var chips: [NSButton] = []
    private var barFrame: CGRect = .zero

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

    // MARK: - Bottom control bar (two rows of chips)

    private func addControls(to view: SelectionView, selected: String) {
        chips.removeAll()
        let general = AreaPreset.general
        let social = AreaPreset.social

        let gW: CGFloat = 74, gH: CGFloat = 60
        let sW: CGFloat = 68, sH: CGFloat = 56
        let gap: CGFloat = 8
        let generalRowW = CGFloat(general.count) * gW + CGFloat(general.count - 1) * gap
        let socialRowW  = CGFloat(social.count)  * sW + CGFloat(social.count - 1)  * gap
        let contentW = max(generalRowW, socialRowW)
        let cardW = contentW + 48
        let cardH: CGFloat = 250

        let card = NSView(frame: NSRect(x: view.bounds.midX - cardW / 2, y: 40, width: cardW, height: cardH))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        view.addSubview(card)
        view.controlsCard = card
        barFrame = card.frame

        // Titles (top-down).
        let hint = NSTextField(labelWithString: "Drag to select an area, or pick a size   ·   then move & resize it   ·   Esc to cancel")
        hint.font = .systemFont(ofSize: 16, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.frame = NSRect(x: 12, y: cardH - 40, width: cardW - 24, height: 22)
        card.addSubview(hint)
        view.hintLabel = hint

        // General row.
        let generalLabel = sectionLabel("Aspect ratios", width: cardW, y: cardH - 66)
        card.addSubview(generalLabel)
        layoutRow(general, startTag: 0, chipW: gW, chipH: gH, gap: gap,
                  rowW: generalRowW, cardW: cardW, y: cardH - 66 - 8 - gH, into: card)

        // Social row.
        let socialLabel = sectionLabel("Social media", width: cardW, y: cardH - 66 - 8 - gH - 26)
        card.addSubview(socialLabel)
        layoutRow(social, startTag: general.count, chipW: sW, chipH: sH, gap: gap,
                  rowW: socialRowW, cardW: cardW, y: 14, into: card)

        highlight(selectedName: selected)
    }

    private func sectionLabel(_ text: String, width: CGFloat, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = NSColor.white.withAlphaComponent(0.55)
        l.alignment = .center
        l.frame = NSRect(x: 12, y: y, width: width - 24, height: 14)
        return l
    }

    private func layoutRow(_ presets: [AreaPreset], startTag: Int, chipW: CGFloat, chipH: CGFloat,
                           gap: CGFloat, rowW: CGFloat, cardW: CGFloat, y: CGFloat, into card: NSView) {
        let startX = (cardW - rowW) / 2
        for (i, preset) in presets.enumerated() {
            let b = NSButton(frame: NSRect(x: startX + CGFloat(i) * (chipW + gap), y: y, width: chipW, height: chipH))
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.imagePosition = .imageAbove
            b.image = preset.icon()
            b.tag = startTag + i
            b.toolTip = preset.name
            b.attributedTitle = NSAttributedString(string: preset.short, attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 10.5, weight: .medium)
            ])
            b.wantsLayer = true
            b.layer?.cornerRadius = 8
            b.target = self
            b.action = #selector(pickPreset(_:))
            card.addSubview(b)
            chips.append(b)
        }
    }

    // MARK: - Selection

    @objc private func pickPreset(_ sender: NSButton) {
        let preset = AreaPreset.all[sender.tag]
        Settings.regionPreset = preset.name
        highlight(selectedName: preset.name)

        guard let aspect = preset.aspect, let screen = NSScreen.main else {
            // Freeform: unlock and let the user drag their own area.
            selectionView?.activeAspect = nil
            selectionView?.clearPreview()
            return
        }
        // Morph a preview frame to a centered rect for this aspect (Mac-style expand), then commit.
        // Fine positioning/resizing happens next on the editable RegionOverlay, where the aspect
        // stays locked.
        selectionView?.activeAspect = aspect
        let target = centeredRect(aspect: aspect, screen: screen.frame)
        selectionView?.animatePreview(to: target) { [weak self] in
            self?.finish(rect: target, screenSize: screen.frame.size)
        }
    }

    /// Largest centered rect of `aspect` that fits comfortably in the area above the control bar.
    private func centeredRect(aspect: CGFloat, screen: CGRect) -> CGRect {
        let reservedBottom = barFrame.maxY + 28
        let avail = CGRect(x: 0, y: reservedBottom, width: screen.width, height: screen.height - reservedBottom - 40)
        let maxW = avail.width * 0.82, maxH = avail.height * 0.92
        var w = maxW, h = maxW / aspect
        if h > maxH { h = maxH; w = maxH * aspect }
        let x = avail.midX - w / 2
        let y = avail.midY - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
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
    var activeAspect: CGFloat?   // when set, drag selection is locked to this width/height ratio
    weak var controlsCard: NSView?
    weak var hintLabel: NSTextField?

    private var start: NSPoint?
    private var current: NSPoint?
    private var didDrag = false

    // Animated preset preview frame (shown briefly while morphing, then the selector commits).
    private var previewRect: CGRect?
    private var animTimer: Timer?
    private var animFrom: CGRect = .zero
    private var animTo: CGRect = .zero
    private var animStart: TimeInterval = 0
    private var animDone: (() -> Void)?
    private let animDuration: TimeInterval = 0.34

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Preview animation

    /// Smoothly morph the preview frame to `target` (smootherstep — no jarring snap), then run
    /// `completion` (commit the selection).
    func animatePreview(to target: CGRect, then completion: (() -> Void)? = nil) {
        animTimer?.invalidate()
        animFrom = previewRect ?? insetToScale(target, 0.82)
        animTo = target
        animDone = completion
        animStart = CACurrentMediaTime()
        controlsCard?.isHidden = false
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] tmr in
            guard let self = self else { tmr.invalidate(); return }
            let p = min(1, (CACurrentMediaTime() - self.animStart) / self.animDuration)
            let e = self.smootherstep(CGFloat(p))
            self.previewRect = self.lerp(self.animFrom, self.animTo, e)
            self.needsDisplay = true
            if p >= 1 {
                tmr.invalidate()
                self.previewRect = self.animTo
                let done = self.animDone; self.animDone = nil
                done?()
            }
        }
    }

    func clearPreview() {
        animTimer?.invalidate(); animTimer = nil
        animDone = nil
        previewRect = nil
        needsDisplay = true
    }

    private func smootherstep(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x)); return t * t * t * (t * (t * 6 - 15) + 10)
    }
    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
    private func insetToScale(_ r: CGRect, _ s: CGFloat) -> CGRect {
        CGRect(x: r.midX - r.width * s / 2, y: r.midY - r.height * s / 2, width: r.width * s, height: r.height * s)
    }

    // MARK: Mouse / keys

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let s = start, let c = current, hypot(c.x - s.x, c.y - s.y) > 5, !didDrag {
            // Dragging on the canvas draws a fresh custom area; drop any preset preview.
            didDrag = true
            controlsCard?.isHidden = true
            clearPreview()
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        // Only a real drag commits a custom area. A plain click does nothing (Esc cancels), so a
        // stray click never blows away the selection.
        if didDrag, let rect = selectionRect(), rect.width > 20, rect.height > 20 { onFinish?(rect) }
        controlsCard?.isHidden = false
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }   // Esc
    }

    private func selectionRect() -> CGRect? {
        guard let s = start, let c = current else { return nil }
        var w = abs(s.x - c.x), h = abs(s.y - c.y)
        if let a = activeAspect, w > 0, h > 0 {
            if w / h > a { w = h * a } else { h = w / a }
        }
        let x = (c.x >= s.x) ? s.x : s.x - w
        let y = (c.y >= s.y) ? s.y : s.y - h
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        // Show the active drag rect, or the animated preset preview.
        guard let rect = selectionRect() ?? previewRect else { return }

        NSColor.clear.set()
        NSBezierPath(rect: rect).setClip()
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
