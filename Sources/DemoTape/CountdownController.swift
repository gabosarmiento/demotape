import AppKit

/// Shows a full-screen "3‑2‑1" countdown overlay so the user can get ready before
/// recording starts. The overlay is click-through and is dismissed before capture
/// begins, so it never appears in the recording.
final class CountdownController {
    private var window: NSWindow?
    private var view: CountdownView?
    private var timer: Timer?
    private var remaining = 0
    private var completion: (() -> Void)?

    /// Counts down from `seconds` (showing each number for ~1s), then calls completion.
    func run(from seconds: Int, completion: @escaping () -> Void) {
        self.completion = completion
        remaining = max(1, seconds)
        showWindow()
        view?.show(number: remaining)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            finish()
        } else {
            view?.show(number: remaining)
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        closeWindow()
        let done = completion
        completion = nil
        done?()
    }

    private func showWindow() {
        guard let screen = NSScreen.main else {
            // No screen? Just proceed immediately.
            finish()
            return
        }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver             // above the menu bar and other windows
        w.ignoresMouseEvents = true        // let the user click through to prepare
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let v = CountdownView(frame: screen.frame)
        w.contentView = v
        w.orderFrontRegardless()

        self.window = w
        self.view = v
    }

    private func closeWindow() {
        window?.orderOut(nil)
        window = nil
        view = nil
    }
}

/// Draws a translucent circle with a large centered number, fading in on each tick.
private final class CountdownView: NSView {
    private var number: Int = 3 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func show(number: Int) {
        self.number = number
        layer?.removeAnimation(forKey: "fade")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.15
        fade.toValue = 1.0
        fade.duration = 0.3
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "fade")
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 240
        let circle = NSRect(x: bounds.midX - diameter / 2,
                            y: bounds.midY - diameter / 2,
                            width: diameter, height: diameter)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let text = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 150, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let origin = NSPoint(x: bounds.midX - size.width / 2,
                             y: bounds.midY - size.height / 2)
        text.draw(at: origin, withAttributes: attrs)
    }
}
