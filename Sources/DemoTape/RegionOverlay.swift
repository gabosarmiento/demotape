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

    private var window: NSWindow?
    private var view: RegionEditView?

    /// `region` is in screen coordinates (bottom-left origin).
    func show(region: CGRect, editable: Bool) {
        guard let screen = NSScreen.main else { return }
        let win = window ?? makeWindow(screen: screen)
        let v = view ?? {
            let v = RegionEditView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.screenOrigin = screen.frame.origin
            v.onChange = { [weak self] r in self?.onChange?(r) }
            win.contentView = v
            view = v
            return v
        }()
        v.regionLocal = CGRect(x: region.minX - screen.frame.minX,
                               y: region.minY - screen.frame.minY,
                               width: region.width, height: region.height)
        setEditable(editable)
        win.orderFrontRegardless()
    }

    func setEditable(_ editable: Bool) {
        window?.ignoresMouseEvents = !editable
        view?.editable = editable
        view?.needsDisplay = true
        if let v = view { window?.invalidateCursorRects(for: v) }
    }

    func hide() { window?.orderOut(nil); window = nil; view = nil }

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
    var editable = false { didSet { needsDisplay = true } }

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

        let path = NSBezierPath(rect: r)
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.5).setStroke()
        NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)).stroke()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.stroke()

        if editable {
            // Small solid corner handles.
            NSColor.white.setFill()
            let s: CGFloat = 8
            for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                      CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
                let box = CGRect(x: c.x - s/2, y: c.y - s/2, width: s, height: s)
                NSColor.black.withAlphaComponent(0.5).setStroke()
                let p = NSBezierPath(rect: box); p.lineWidth = 1
                NSColor.white.setFill(); box.fill(using: .sourceOver)
                NSBezierPath(rect: box).fill()
                p.stroke()
            }
        }
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
        setCursor(for: zone(at: convert(event.locationInWindow, from: nil)))
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim clicks in/around the region; let clicks elsewhere pass through.
        guard editable else { return nil }
        return regionLocal.insetBy(dx: -grab, dy: -grab).contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
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
        let r = regionLocal, g = grab
        guard r.insetBy(dx: -g, dy: -g).contains(p) else { return .none }
        let nl = abs(p.x - r.minX) <= g, nr = abs(p.x - r.maxX) <= g
        let nb = abs(p.y - r.minY) <= g, nt = abs(p.y - r.maxY) <= g
        if nl && nt { return .tl }; if nr && nt { return .tr }
        if nl && nb { return .bl }; if nr && nb { return .br }
        if nl { return .left }; if nr { return .right }
        if nt { return .top }; if nb { return .bottom }
        return r.contains(p) ? .move : .none
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
