import AppKit

/// Editor for the teleprompter. Two tabs:
///  - **Script**: paste text, pick a scroll speed (or fit to a duration), Test it live.
///  - **Display**: choose which edge the full-screen strip sits on (top/bottom/left/right),
///    shown on a diagram of the capture area. That strip is excluded from the recording.
@available(macOS 12.3, *)
final class TeleprompterSettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private var escMonitor: Any?
    private let preview = TeleprompterOverlay()

    // Tabs
    private var tabPicker: NSSegmentedControl!
    private var scriptViews: [NSView] = []
    private var displayViews: [NSView] = []

    // Script controls
    private var textView: NSTextView!
    private var speedSeg: NSSegmentedControl!
    private var speedRow: NSView!
    private var fitCheckbox: NSButton!
    private var minutesSlider: NSSlider!
    private var minutesLabel: NSTextField!
    private var minutesRow: NSView!
    private var testButton: NSButton!

    // Display controls
    private var diagram: StripDiagramView!
    private var edgeSeg: NSSegmentedControl!

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private let edges = ["top", "bottom", "left", "right"]

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let w: CGFloat = 640, h: CGFloat = 520
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Teleprompter"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Tab switcher.
        tabPicker = NSSegmentedControl(labels: ["Script", "Display"],
                                       trackingMode: .selectOne, target: self, action: #selector(tabChanged))
        tabPicker.selectedSegment = 0
        tabPicker.frame = NSRect(x: w/2 - 110, y: h - 44, width: 220, height: 26)
        content.addSubview(tabPicker)

        buildScriptTab(in: content, w: w, h: h)
        buildDisplayTab(in: content, w: w, h: h)

        // Buttons (shared).
        testButton = NSButton(title: "Test", target: self, action: #selector(toggleTest))
        testButton.bezelStyle = .rounded
        testButton.frame = NSRect(x: 16, y: 16, width: 120, height: 32)
        content.addSubview(testButton)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: w - 236, y: 16, width: 100, height: 32)
        content.addSubview(cancel)
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        save.frame = NSRect(x: w - 126, y: 16, width: 110, height: 32)
        content.addSubview(save)

        window.contentView = content
        self.window = window
        showTab(0)
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.window != nil, e.keyCode == 53 else { return e }
            self.window?.close(); return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Tabs

    private func buildScriptTab(in content: NSView, w: CGFloat, h: CGFloat) {
        let header = NSTextField(wrappingLabelWithString:
            "Paste your script and pick a scroll speed (1× is a natural reading pace). It scrolls "
            + "in the strip you choose under Display — excluded from the recording.")
        header.font = .systemFont(ofSize: 11); header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 16, y: h - 92, width: w - 32, height: 34)
        content.addSubview(header)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 150, width: w - 32, height: h - 250))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.autoresizingMask = [.width]; tv.isRichText = false
        tv.font = .systemFont(ofSize: 14); tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.string = Settings.teleprompterText
        scroll.documentView = tv
        content.addSubview(scroll); textView = tv

        speedRow = NSView(frame: NSRect(x: 16, y: 104, width: w - 32, height: 26))
        let speedTitle = NSTextField(labelWithString: "Speed"); speedTitle.font = .systemFont(ofSize: 12)
        speedTitle.frame = NSRect(x: 0, y: 4, width: 54, height: 18); speedRow.addSubview(speedTitle)
        speedSeg = NSSegmentedControl(labels: ["0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"],
                                      trackingMode: .selectOne, target: nil, action: nil)
        speedSeg.frame = NSRect(x: 58, y: 0, width: 360, height: 26)
        speedSeg.selectedSegment = speeds.firstIndex(of: Settings.teleprompterSpeed) ?? 2
        speedRow.addSubview(speedSeg)
        content.addSubview(speedRow)

        minutesRow = NSView(frame: NSRect(x: 16, y: 104, width: w - 32, height: 26))
        let durTitle = NSTextField(labelWithString: "Duration"); durTitle.font = .systemFont(ofSize: 12)
        durTitle.frame = NSRect(x: 0, y: 4, width: 70, height: 18); minutesRow.addSubview(durTitle)
        minutesSlider = NSSlider(value: Settings.teleprompterMinutes, minValue: 0.5, maxValue: 10,
                                 target: self, action: #selector(minutesChanged))
        minutesSlider.frame = NSRect(x: 74, y: 2, width: w - 32 - 74 - 110, height: 22)
        minutesRow.addSubview(minutesSlider)
        minutesLabel = NSTextField(labelWithString: "")
        minutesLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        minutesLabel.textColor = .secondaryLabelColor
        minutesLabel.frame = NSRect(x: w - 32 - 100, y: 4, width: 100, height: 18)
        minutesRow.addSubview(minutesLabel)
        content.addSubview(minutesRow); updateMinutesLabel()

        fitCheckbox = NSButton(checkboxWithTitle: "  Fit to a set duration",
                               target: self, action: #selector(fitToggled))
        fitCheckbox.state = Settings.teleprompterFitDuration ? .on : .off
        fitCheckbox.frame = NSRect(x: 16, y: 74, width: 300, height: 20)
        content.addSubview(fitCheckbox)
        applyFitState()

        scriptViews = [header, scroll, speedRow, minutesRow, fitCheckbox]
    }

    private func buildDisplayTab(in content: NSView, w: CGFloat, h: CGFloat) {
        let help = NSTextField(wrappingLabelWithString:
            "In full-screen recording, a thin strip on this edge is reserved for the teleprompter "
            + "and is NOT recorded. Pick where it sits. (In Select Recording Area mode, it scrolls "
            + "in the empty space around your selection instead.)")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 16, y: h - 104, width: w - 32, height: 46)
        content.addSubview(help)

        diagram = StripDiagramView(frame: NSRect(x: w/2 - 190, y: 150, width: 380, height: 220))
        diagram.edge = Settings.teleprompterStripEdge
        content.addSubview(diagram)

        edgeSeg = NSSegmentedControl(labels: ["Top", "Bottom", "Left", "Right"],
                                     trackingMode: .selectOne, target: self, action: #selector(edgeChanged))
        edgeSeg.selectedSegment = edges.firstIndex(of: Settings.teleprompterStripEdge) ?? 0
        edgeSeg.frame = NSRect(x: w/2 - 180, y: 108, width: 360, height: 26)
        content.addSubview(edgeSeg)

        displayViews = [help, diagram, edgeSeg]
    }

    @objc private func tabChanged() { showTab(tabPicker.selectedSegment) }
    private func showTab(_ index: Int) {
        scriptViews.forEach { $0.isHidden = index != 0 }
        displayViews.forEach { $0.isHidden = index != 1 }
        if index == 0 { applyFitState() }   // keep the speed/minutes visibility correct
    }

    // MARK: - Script controls

    private func applyFitState() {
        guard tabPicker.selectedSegment == 0 else { return }
        let fit = fitCheckbox.state == .on
        minutesRow.isHidden = !fit
        speedRow.isHidden = fit
    }
    @objc private func fitToggled() { applyFitState() }
    @objc private func minutesChanged() { updateMinutesLabel() }
    private func updateMinutesLabel() {
        let m = minutesSlider.doubleValue
        minutesLabel.stringValue = m < 1 ? String(format: "%.0f sec", m * 60)
                                         : String(format: "%.1f min", m)
    }
    private var currentSpeed: Double { speeds[max(0, speedSeg.selectedSegment)] }
    private var currentEdge: String { edges[max(0, edgeSeg.selectedSegment)] }

    @objc private func edgeChanged() { diagram.edge = currentEdge }

    // MARK: - Test / save

    @objc private func toggleTest() {
        if preview.isRunning {
            preview.stop(); testButton.title = "Test"
        } else {
            let minutes = TeleprompterOverlay.scrollMinutes(
                text: textView.string, speed: currentSpeed,
                fit: fitCheckbox.state == .on, fitMinutes: minutesSlider.doubleValue)
            preview.showPreview(text: textView.string, minutes: minutes, edge: currentEdge,
                                fraction: CGFloat(Settings.teleprompterTopStripFraction))
            testButton.title = "Stop Test"
        }
    }

    @objc private func save() {
        Settings.teleprompterText = textView.string
        Settings.teleprompterSpeed = currentSpeed
        Settings.teleprompterFitDuration = (fitCheckbox.state == .on)
        Settings.teleprompterMinutes = minutesSlider.doubleValue
        Settings.teleprompterStripEdge = currentEdge
        Settings.teleprompterEnabled = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        window?.close()
    }

    @objc private func cancel() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        preview.stop()
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        window = nil
        onClose?(); onClose = nil
    }
}

/// A schematic of the display showing the recorded area and the reserved teleprompter strip.
private final class StripDiagramView: NSView {
    var edge: String = "top" { didSet { needsDisplay = true } }
    private let fraction: CGFloat = 0.16   // slightly emphasized vs. the real 0.12 for legibility

    override func draw(_ dirtyRect: NSRect) {
        let screen = bounds.insetBy(dx: 8, dy: 8)
        let sh = screen.height * fraction, sw = screen.width * fraction
        var strip = screen, recorded = screen
        switch edge {
        case "bottom":
            strip = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: sh)
            recorded = CGRect(x: screen.minX, y: screen.minY + sh, width: screen.width, height: screen.height - sh)
        case "left":
            strip = CGRect(x: screen.minX, y: screen.minY, width: sw, height: screen.height)
            recorded = CGRect(x: screen.minX + sw, y: screen.minY, width: screen.width - sw, height: screen.height)
        case "right":
            strip = CGRect(x: screen.maxX - sw, y: screen.minY, width: sw, height: screen.height)
            recorded = CGRect(x: screen.minX, y: screen.minY, width: screen.width - sw, height: screen.height)
        default: // top
            strip = CGRect(x: screen.minX, y: screen.maxY - sh, width: screen.width, height: sh)
            recorded = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - sh)
        }

        // Recorded area.
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: recorded, xRadius: 6, yRadius: 6).fill()
        // Teleprompter strip.
        NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6).fill()
        // Screen outline.
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let outline = NSBezierPath(roundedRect: screen, xRadius: 8, yRadius: 8)
        outline.lineWidth = 1.5; outline.stroke()

        label("Recorded", in: recorded, color: NSColor.white.withAlphaComponent(0.8))
        label("Teleprompter", in: strip, color: .white)
    }

    private func label(_ text: String, in rect: CGRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        guard rect.width > size.width, rect.height > size.height else { return }
        s.draw(at: NSPoint(x: rect.midX - size.width/2, y: rect.midY - size.height/2), withAttributes: attrs)
    }
}
