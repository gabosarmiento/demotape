import AppKit

/// Persistent recording-area overlay. Two modes:
///  - **editable**: the selected area can be moved (drag inside) and resized (drag edges/
///    corners), with matching cursors, like resizing a window. Clicking outside does nothing.
///  - **recording** (not editable): click-through, just draws the dashed border — drawn a few
///    px *outside* the recorded area so it never appears in the capture.
@available(macOS 12.3, *)
final class RegionOverlay {

    /// Called with the region in screen coordinates (bottom-left origin) whenever it changes.
    var onChange: ((CGRect) -> Void)?
    /// The user tapped the lock/unlock pill on the overlay.
    var onToggleLock: (() -> Void)?
    /// When set, resizing keeps this width/height ratio.
    var aspect: CGFloat?

    private var window: NSWindow?
    private var view: RegionEditView?
    /// A tiny always-interactive panel holding the "Unlock" button, shown while locked. The big
    /// region window goes fully click-through when locked, so this small panel is the one thing that
    /// still catches a click — guaranteeing you can reach the app beneath everywhere else.
    private var unlockPanel: NSPanel?

    /// `region` is in screen coordinates (bottom-left origin).
    func show(region: CGRect, editable: Bool) {
        guard let screen = NSScreen.main else { return }
        let win = window ?? makeWindow(screen: screen)
        let v = view ?? {
            let v = RegionEditView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.screenOrigin = screen.frame.origin
            v.onChange = { [weak self] r in self?.onChange?(r) }
            v.onToggleLock = { [weak self] in self?.onToggleLock?() }
            win.contentView = v
            view = v
            return v
        }()
        v.regionLocal = CGRect(x: region.minX - screen.frame.minX,
                               y: region.minY - screen.frame.minY,
                               width: region.width, height: region.height)
        v.aspect = aspect
        setEditable(editable)
        win.orderFrontRegardless()
    }

    func setEditable(_ editable: Bool) {
        window?.ignoresMouseEvents = !editable
        view?.editable = editable
        view?.needsDisplay = true
        if !editable { hideUnlockPanel() }   // recording: no unlock affordance
        if let v = view { window?.invalidateCursorRects(for: v) }
    }

    /// Lock the framed area in place: the big overlay goes fully click-through (so you can click,
    /// scroll and type in the app beneath everywhere) while still drawing the accepted green region,
    /// and a small "Unlock" panel lets you adjust again. Only meaningful while idle (`editable`).
    func setLocked(_ locked: Bool) {
        view?.locked = locked
        if locked {
            window?.ignoresMouseEvents = true          // everything falls through to the app beneath
            showUnlockPanel()
        } else {
            window?.ignoresMouseEvents = false         // move/resize the region again
            hideUnlockPanel()
        }
        view?.needsDisplay = true
    }

    /// Position the small unlock panel straddling the top border of the (locked) region.
    private func showUnlockPanel() {
        guard let v = view else { return }
        let r = v.regionLocal.insetBy(dx: -4, dy: -4)
        let w: CGFloat = 132, h: CGFloat = 30
        let x = r.midX + v.screenOrigin.x - w / 2
        let y = r.maxY + v.screenOrigin.y - h / 2
        let panel = unlockPanel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            // Above the region overlay AND the recorder bar (floating+1) so it's always reachable.
            p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.95).cgColor
            content.layer?.cornerRadius = h / 2
            content.layer?.cornerCurve = .continuous
            let btn = ClosureButton(title: "🔓  Unlock") { [weak self] in self?.onToggleLock?() }
            btn.isBordered = false
            btn.wantsLayer = true
            btn.frame = content.bounds
            btn.attributedTitle = NSAttributedString(string: "🔓  Unlock", attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ])
            content.addSubview(btn)
            p.contentView = content
            unlockPanel = p
            return p
        }()
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    private func hideUnlockPanel() { unlockPanel?.orderOut(nil); unlockPanel = nil }

    func hide() {
        hideUnlockPanel()
        window?.orderOut(nil); window = nil; view = nil
    }

    private func makeWindow(screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating          // below the recorder bar (which is floating+1)
        w.hasShadow = false
        w.acceptsMouseMovedEvents = true
        w.sharingType = .none        // best-effort; the border is drawn outside the crop regardless
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window = w
        return w
    }
}

/// Draws the dashed frame + corner handles and handles move/resize interaction.
private final class RegionEditView: NSView {
    var screenOrigin: CGPoint = .zero
    var onChange: ((CGRect) -> Void)?
    var onToggleLock: (() -> Void)?
    var editable = false { didSet { needsDisplay = true } }
    /// Accepted-and-fixed: draw the region + an unlock pill, but let clicks fall through so the user
    /// can prepare the app they're about to record.
    var locked = false { didSet { needsDisplay = true } }
    var aspect: CGFloat?

    /// Region in view-local coordinates (bottom-left origin).
    var regionLocal: CGRect = .zero { didSet { needsDisplay = true } }

    private let grab: CGFloat = 12
    private let minSize = CGSize(width: 120, height: 90)
    private let gap: CGFloat = 4        // clear space between content and the drawn border

    private enum Zone { case none, move, left, right, top, bottom, tl, tr, bl, br }
    private var dragZone: Zone = .none
    private var dragStart: NSPoint = .zero
    private var origRegion: CGRect = .zero

    override var isFlipped: Bool { false }   // bottom-left origin

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard regionLocal.width > 0 else { return }
        let r = regionLocal.insetBy(dx: -gap, dy: -gap)   // border sits outside the recorded pixels

        // A locked area reads as "accepted" — a solid green frame instead of the white dashed one.
        let path = NSBezierPath(rect: r)
        path.lineWidth = 2
        NSColor.black.withAlphaComponent(0.5).setStroke()
        NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)).stroke()
        if locked {
            NSColor.systemGreen.setStroke()
            path.stroke()
        } else {
            path.setLineDash([7, 5], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }

        // Locked: just the green frame — the separate "Unlock" panel is the only live control, so the
        // whole overlay is click-through to the app beneath. Nothing more to draw here.
        guard editable, !locked else { return }

        // Small solid corner handles.
        let s: CGFloat = 8
        for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let box = CGRect(x: c.x - s/2, y: c.y - s/2, width: s, height: s)
            NSColor.white.setFill(); box.fill(using: .sourceOver)
            NSBezierPath(rect: box).fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            NSBezierPath(rect: box).stroke()
        }
        drawPill(movePillRect, text: "Drag to move")
        drawPill(lockPillRect, text: "🔒  Lock")
    }

    /// Draws a rounded dark control pill with centered text.
    private func drawPill(_ rect: CGRect, text: String) {
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.66).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke(); pill.lineWidth = 1; pill.stroke()
        let label = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let sz = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2), withAttributes: attrs)
    }

    // MARK: - Cursors

    // The overlay window isn't key, so cursor *rects* never fire — drive the cursor from a
    // tracking area's mouseMoved instead.
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if editable, lockPillRect.contains(p) { NSCursor.pointingHand.set(); return }
        if locked { NSCursor.arrow.set(); return }
        setCursor(for: zone(at: p))
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    private func setCursor(for zone: Zone) {
        guard editable else { return }
        switch zone {
        case .left, .right:  NSCursor.resizeLeftRight.set()
        case .top, .bottom:  NSCursor.resizeUpDown.set()
        case .tl, .br:       Self.diag(neSW: false).set()
        case .tr, .bl:       Self.diag(neSW: true).set()
        case .move:          NSCursor.openHand.set()   // hand = draggable
        case .none:          NSCursor.arrow.set()
        }
    }

    /// Diagonal window-resize cursors are private; try them, fall back to a public cursor.
    private static func diag(neSW: Bool) -> NSCursor {
        let name = neSW ? "_windowResizeNorthEastSouthWestCursor" : "_windowResizeNorthWestSouthEastCursor"
        let sel = NSSelectorFromString(name)
        if NSCursor.responds(to: sel),
           let c = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor { return c }
        return .crosshair
    }



    // MARK: - Interaction

    private let pillH: CGFloat = 26
    private let movePillW: CGFloat = 104
    private let lockPillW: CGFloat = 96
    private let lockedPillW: CGFloat = 132
    private let pillGap: CGFloat = 8

    /// The "Drag to move" pill straddling the top border (shown only while unlocked). The interior
    /// stays click-through, so this is the discoverable way to reposition the whole area.
    private var movePillRect: CGRect {
        let r = regionLocal.insetBy(dx: -gap, dy: -gap)
        let total = movePillW + pillGap + lockPillW
        return CGRect(x: r.midX - total / 2, y: r.maxY - pillH / 2, width: movePillW, height: pillH)
    }

    /// The lock / unlock pill. Unlocked: sits right of the move pill ("Lock"). Locked: centered on
    /// the top border on its own ("Unlock"), and it's the only live target so the rest falls through.
    private var lockPillRect: CGRect {
        let r = regionLocal.insetBy(dx: -gap, dy: -gap)
        if locked {
            return CGRect(x: r.midX - lockedPillW / 2, y: r.maxY - pillH / 2, width: lockedPillW, height: pillH)
        }
        let total = movePillW + pillGap + lockPillW
        return CGRect(x: r.midX - total / 2 + movePillW + pillGap, y: r.maxY - pillH / 2,
                      width: lockPillW, height: pillH)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Recording (not editable): pass everything through.
        guard editable else { return nil }
        // The (un)lock pill is always live so you can toggle it.
        if lockPillRect.contains(point) { return self }
        // Locked: nothing else is interactive — clicks reach the app beneath.
        if locked { return nil }
        // Unlocked: the move pill and the resize border band; interior + outside fall through.
        if movePillRect.contains(point) { return self }
        let outer = regionLocal.insetBy(dx: -grab, dy: -grab)
        let inner = regionLocal.insetBy(dx: grab, dy: grab)
        return (outer.contains(point) && !inner.contains(point)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if lockPillRect.contains(p) { onToggleLock?(); return }   // toggle, never a drag
        guard !locked else { return }
        dragZone = zone(at: p)
        dragStart = p
        origRegion = regionLocal
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragZone != .none else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        regionLocal = apply(zone: dragZone, dx: dx, dy: dy, to: origRegion)
        if dragZone == .move { NSCursor.closedHand.set() }   // grabbing
        else { setCursor(for: dragZone) }                    // keep the resize cursor
        onChange?(CGRect(x: regionLocal.minX + screenOrigin.x, y: regionLocal.minY + screenOrigin.y,
                         width: regionLocal.width, height: regionLocal.height))
    }

    override func mouseUp(with event: NSEvent) { dragZone = .none }

    private func zone(at p: NSPoint) -> Zone {
        if movePillRect.contains(p) { return .move }   // the pill moves the whole region
        let r = regionLocal, g = grab
        guard r.insetBy(dx: -g, dy: -g).contains(p) else { return .none }
        let nl = abs(p.x - r.minX) <= g, nr = abs(p.x - r.maxX) <= g
        let nb = abs(p.y - r.minY) <= g, nt = abs(p.y - r.maxY) <= g
        if nl && nt { return .tl }; if nr && nt { return .tr }
        if nl && nb { return .bl }; if nr && nb { return .br }
        if nl { return .left }; if nr { return .right }
        if nt { return .top }; if nb { return .bottom }
        return .none   // interior is click-through now (move via the pill), so no drag here
    }

    private func apply(zone: Zone, dx: CGFloat, dy: CGFloat, to o: CGRect) -> CGRect {
        var r = o
        switch zone {
        case .move:
            r.origin.x += dx; r.origin.y += dy
        case .left:   r.origin.x += dx; r.size.width -= dx
        case .right:  r.size.width += dx
        case .top:    r.size.height += dy
        case .bottom: r.origin.y += dy; r.size.height -= dy
        case .tl:     r.origin.x += dx; r.size.width -= dx; r.size.height += dy
        case .tr:     r.size.width += dx; r.size.height += dy
        case .bl:     r.origin.x += dx; r.size.width -= dx; r.origin.y += dy; r.size.height -= dy
        case .br:     r.size.width += dx; r.origin.y += dy; r.size.height -= dy
        case .none:   break
        }
        // Keep the locked aspect ratio (width drives height); keep the opposite edge fixed.
        if let a = aspect, zone != .move, zone != .none {
            let newH = r.size.width / a
            if zone == .bottom || zone == .bl || zone == .br {
                r.origin.y += (r.size.height - newH)
            }
            r.size.height = newH
        }
        return clamp(r)
    }

    private func clamp(_ rect: CGRect) -> CGRect {
        var r = rect
        r.size.width = max(minSize.width, r.size.width)
        r.size.height = max(minSize.height, r.size.height)
        // Keep within the screen.
        r.origin.x = min(max(r.origin.x, 0), bounds.width - r.size.width)
        r.origin.y = min(max(r.origin.y, 0), bounds.height - r.size.height)
        r.size.width = min(r.size.width, bounds.width - r.origin.x)
        r.size.height = min(r.size.height, bounds.height - r.origin.y)
        return r
    }
}

/// A borderless button that runs a closure — used for the small floating "Unlock" panel.
private final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fire() { handler() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
