import AppKit

/// A floating control bar (screen-recorder HUD) shown once a capture mode is chosen.
/// Start/Stop, a running timer, mic + webcam toggles, and a cancel (✕) that just dismisses
/// the bar (never quits the app). Non-activating so it floats over other apps, and draggable
/// anywhere on screen.
@available(macOS 12.3, *)
final class RecorderBarController: NSObject {

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleMic: (() -> Void)?
    var onToggleWebcam: (() -> Void)?

    private var panel: KeyablePanel?
    private var recordButton: NSButton!
    private var timerLabel: NSTextField!
    private var micButton: BarHoverButton!
    private var webcamButton: BarHoverButton!
    private var cancelButton: BarHoverButton!
    private var focusables: [NSButton] = []
    private var keyMonitor: Any?
    private var timer: Timer?
    private var startTime: Date?
    private var userMoved = false
    private var previousApp: NSRunningApplication?
    private(set) var isRecording = false

    private let barSize = NSSize(width: 300, height: 42)

    // MARK: - Show / hide

    func show(anchorRegion: CGRect?, micOn: Bool, webcamOn: Bool) {
        if panel == nil { build() }
        userMoved = false
        updateMic(micOn)
        updateWebcam(webcamOn)
        setRecording(false)
        position(anchorRegion: anchorRegion)
        // Remember who was active so we can hand keyboard focus back when recording starts.
        previousApp = NSWorkspace.shared.frontmostApplication
        panel?.makeKeyAndOrderFront(nil)          // key so Tab/Enter reach the buttons
        panel?.makeFirstResponder(recordButton)
        installKeyMonitor()
    }

    /// Tab/Enter/Space navigation for the bar, independent of macOS "Full Keyboard Access"
    /// (which otherwise blocks Tab between buttons).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 48:  // Tab
                self.focusAdjacent(event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            case 49, 36, 76:  // Space, Return, keypad Enter
                (panel.firstResponder as? NSButton)?.performClick(nil)
                return nil
            default:
                return event
            }
        }
    }

    private func focusAdjacent(_ delta: Int) {
        guard !focusables.isEmpty, let panel = panel else { return }
        let current = focusables.firstIndex { $0 == panel.firstResponder } ?? 0
        let next = (current + delta + focusables.count) % focusables.count
        panel.makeFirstResponder(focusables[next])
    }

    /// Give keyboard focus back to the app being recorded (called when recording begins),
    /// so the user's typing goes to their content, not the bar.
    func relinquishKeyFocus() {
        previousApp?.activate(options: [])
    }

    /// Reposition to follow a region, unless the user has dragged the bar themselves.
    func reposition(anchorRegion: CGRect?) {
        guard !userMoved else { return }
        position(anchorRegion: anchorRegion)
    }

    func hide() {
        stopTimer()
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
    }

    /// Hide without tearing down (full-screen recording, where the bar would be captured).
    func setHiddenDuringCapture(_ hidden: Bool) {
        if hidden { panel?.orderOut(nil) } else { panel?.orderFrontRegardless() }
    }

    // MARK: - State

    func setRecording(_ recording: Bool) {
        isRecording = recording
        recordButton.image = symbol(recording ? "stop.fill" : "record.circle", size: 12)
        recordButton.title = recording ? "  Stop" : "  Start"
        recordButton.contentTintColor = recording ? .white : .systemRed
        recordButton.toolTip = recording ? "Stop recording" : "Start recording"
        if recording { startTimer() } else { stopTimer(); timerLabel.stringValue = "00:00" }
    }

    func updateMic(_ on: Bool) {
        micButton.image = symbol(on ? "mic.fill" : "mic.slash.fill", size: 13)
        micButton.contentTintColor = on ? .white : .tertiaryLabelColor
        micButton.toolTip = on ? "Microphone (on)" : "Microphone (off)"
    }

    func updateWebcam(_ on: Bool) {
        webcamButton.image = symbol(on ? "video.fill" : "video.slash.fill", size: 13)
        webcamButton.contentTintColor = on ? .white : .tertiaryLabelColor
        webcamButton.toolTip = on ? "Webcam (on)" : "Webcam (off)"
    }

    // MARK: - Build

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return img?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }

    private func build() {
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: barSize),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hasShadow = false                    // no dark border/shadow ring
        panel.sharingType = .none                  // best-effort; note AVCaptureScreenInput ignores it
                                                   // (full-screen recording hides the bar instead)
        panel.isMovableByWindowBackground = true   // drag the bar anywhere
        panel.autorecalculatesKeyViewLoop = true   // Tab cycles the buttons
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = DragBackgroundView(frame: NSRect(origin: .zero, size: barSize))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 11
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        recordButton = NSButton(title: "  Start", target: self, action: #selector(toggleRecord))
        recordButton.image = symbol("record.circle", size: 12)
        recordButton.imagePosition = .imageLeading
        recordButton.bezelStyle = .rounded
        recordButton.contentTintColor = .systemRed
        recordButton.toolTip = "Start recording"
        recordButton.frame = NSRect(x: 8, y: 7, width: 96, height: 28)
        blur.addSubview(recordButton)

        timerLabel = NSTextField(labelWithString: "00:00")
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timerLabel.textColor = .white
        timerLabel.alignment = .center
        timerLabel.frame = NSRect(x: 110, y: 12, width: 50, height: 18)
        blur.addSubview(timerLabel)

        addSeparator(to: blur, x: 168)

        micButton = iconButton(action: #selector(tapMic), x: 180)
        blur.addSubview(micButton)
        webcamButton = iconButton(action: #selector(tapWebcam), x: 210)
        blur.addSubview(webcamButton)

        addSeparator(to: blur, x: 244)

        cancelButton = iconButton(action: #selector(tapCancel), x: 262)
        cancelButton.image = symbol("xmark", size: 12)
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.toolTip = "Cancel recording"
        blur.addSubview(cancelButton)

        panel.contentView = blur
        panel.initialFirstResponder = recordButton
        focusables = [recordButton, micButton, webcamButton, cancelButton]
        self.panel = panel
    }

    private func addSeparator(to view: NSView, x: CGFloat) {
        let sep = NSBox(frame: NSRect(x: x, y: 9, width: 1, height: 24))
        sep.boxType = .separator
        view.addSubview(sep)
    }

    private func iconButton(action: Selector, x: CGFloat) -> BarHoverButton {
        let b = BarHoverButton(frame: NSRect(x: x, y: 8, width: 26, height: 26))
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleNone
        b.contentTintColor = .white
        b.target = self
        b.action = action
        return b
    }

    private func position(anchorRegion: CGRect?) {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let f = screen.frame
        let gap: CGFloat = 14
        var x = f.midX - barSize.width / 2
        var y = f.maxY - barSize.height - gap
        if let r = anchorRegion {
            x = r.midX - barSize.width / 2
            if r.maxY + gap + barSize.height <= f.maxY { y = r.maxY + gap }
            else if r.minY - gap - barSize.height >= f.minY { y = r.minY - gap - barSize.height }
            else { y = f.maxY - barSize.height - gap }
        }
        x = min(max(x, f.minX + 8), f.maxX - barSize.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Timer

    private func startTimer() {
        startTime = Date()
        timerLabel.stringValue = "00:00"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let s = Int(Date().timeIntervalSince(start))
            self.timerLabel.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil; startTime = nil }

    // MARK: - Actions

    @objc private func toggleRecord() { isRecording ? onStop?() : onStart?() }
    @objc private func tapMic() { onToggleMic?() }
    @objc private func tapWebcam() { onToggleWebcam?() }
    @objc private func tapCancel() { onCancel?() }
}

/// A non-activating panel that can still become key, so Tab/Enter reach its buttons.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The bar's blurred background — shows an open-hand cursor so users know it's draggable.
final class DragBackgroundView: NSVisualEffectView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// A borderless button that shows it's clickable: pointing-hand cursor + subtle hover fill.
final class BarHoverButton: NSButton {
    private var tracking: NSTrackingArea?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(0.16).cgColor
                                    : NSColor.clear.cgColor
    }
}
