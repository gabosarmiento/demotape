import AppKit

/// A small floating HUD shown while DemoTape auto-renders a recording. Rendering (plus optional
/// audio cleanup) can take a couple of minutes on a long clip, and the only prior signal was the
/// menu-bar icon — easy to miss. This gives clear, non-interactive feedback: a title, a progress
/// bar during the render pass, and a spinner for the audio stages that don't report progress.
@available(macOS 12.3, *)
final class RenderHUD {

    private var panel: NSPanel?
    private var titleLabel: NSTextField!
    private var percentLabel: NSTextField!
    private var bar: NSProgressIndicator!

    private let width: CGFloat = 320
    private let height: CGFloat = 92

    /// Shows the HUD (creating it if needed) with an initial stage message.
    func show(stage: String) {
        if panel == nil { build() }
        titleLabel.stringValue = stage
        setProgress(0)
        position()
        panel?.orderFrontRegardless()
    }

    /// Sets a determinate progress fraction (0…1) for the render pass.
    func setProgress(_ fraction: Double) {
        guard let bar = bar else { return }
        if bar.isIndeterminate {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
        }
        let pct = max(0, min(1, fraction))
        bar.doubleValue = pct
        percentLabel.isHidden = false
        percentLabel.stringValue = "\(Int(pct * 100))%"
    }

    /// Switches to an indeterminate spinner with a new stage label (for steps without progress,
    /// e.g. audio cleanup).
    func setIndeterminate(stage: String) {
        guard let bar = bar else { return }
        titleLabel.stringValue = stage
        percentLabel.isHidden = true
        if !bar.isIndeterminate {
            bar.isIndeterminate = true
        }
        bar.startAnimation(nil)
    }

    /// Hides and tears down the HUD.
    func hide() {
        bar?.stopAnimation(nil)
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Build

    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true            // purely informational
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 18, y: height - 40, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "Rendering")
        icon.contentTintColor = .secondaryLabelColor
        blur.addSubview(icon)

        titleLabel = NSTextField(labelWithString: "Rendering your DemoTape…")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.frame = NSRect(x: 46, y: height - 42, width: width - 100, height: 20)
        blur.addSubview(titleLabel)

        percentLabel = NSTextField(labelWithString: "0%")
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.frame = NSRect(x: width - 62, y: height - 42, width: 44, height: 20)
        blur.addSubview(percentLabel)

        bar = NSProgressIndicator(frame: NSRect(x: 18, y: 24, width: width - 36, height: 16))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.style = .bar
        blur.addSubview(bar)

        let hint = NSTextField(labelWithString: "You can keep working — we'll notify you when it's ready.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 18, y: 6, width: width - 36, height: 14)
        blur.addSubview(hint)

        panel.contentView = blur
        self.panel = panel
    }

    /// Centers horizontally near the top of the screen with the menu bar.
    private func position() {
        guard let panel = panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - width / 2
        let y = frame.maxY - height - 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
