import AppKit
import CoreGraphics
import ApplicationServices

/// First-run screen shown once. It leads with what DemoTape does (a compact feature showcase)
/// and only asks for permissions that are still missing — granted ones drop away so returning
/// users aren't nagged. Everything stays reachable later from the menu.
@available(macOS 12.3, *)
final class WelcomeController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var onFinish: (() -> Void)?
    private var permissionsBox: NSView!
    private var refreshTimer: Timer?

    private let w: CGFloat = 620
    private let leftX: CGFloat = 40

    func show(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let h: CGFloat = 430
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Welcome to DemoTape"
        win.isReleasedWhenClosed = false
        win.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Header.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
           let icon = NSImage(contentsOf: url) {
            let iv = NSImageView(frame: NSRect(x: leftX, y: h - 76, width: 48, height: 48))
            iv.image = icon
            iv.imageScaling = .scaleProportionallyUpOrDown
            content.addSubview(iv)
        }
        let name = NSTextField(labelWithString: "Welcome to DemoTape")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        name.frame = NSRect(x: leftX + 62, y: h - 60, width: w - leftX - 62 - 40, height: 28)
        content.addSubview(name)
        let tagline = NSTextField(labelWithString: "Record once — get a polished, auto-edited demo.")
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.frame = NSRect(x: leftX + 62, y: h - 80, width: w - leftX - 62 - 40, height: 18)
        content.addSubview(tagline)

        // Feature showcase — four compact cells.
        let features: [(String, String)] = [
            ("plus.magnifyingglass", "Auto-zoom\non clicks"),
            ("cursorarrow.rays", "Smooth cursor\n+ key badges"),
            ("person.crop.circle", "Webcam\noverlay"),
            ("square.and.arrow.up", "Web MP4,\ncaptions, voice")
        ]
        let cellW = (w - leftX * 2) / CGFloat(features.count)
        for (i, f) in features.enumerated() {
            addFeatureCell(symbol: f.0, title: f.1,
                           x: leftX + CGFloat(i) * cellW, width: cellW, y: h - 190, on: content)
        }

        let divider = NSBox(frame: NSRect(x: leftX, y: h - 214, width: w - leftX * 2, height: 1))
        divider.boxType = .separator
        content.addSubview(divider)

        // Permissions area (rebuilt live; only shows what's still missing).
        permissionsBox = NSView(frame: NSRect(x: leftX, y: 78, width: w - leftX * 2, height: h - 214 - 78))
        content.addSubview(permissionsBox)

        let start = NSButton(title: "Start using DemoTape", target: self, action: #selector(finish))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        start.frame = NSRect(x: w - leftX - 200, y: 26, width: 200, height: 34)
        content.addSubview(start)

        win.contentView = content
        self.window = win
        win.center()
        rebuildPermissions()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.rebuildPermissions()
        }
    }

    private func addFeatureCell(symbol: String, title: String, x: CGFloat, width: CGFloat,
                                y: CGFloat, on view: NSView) {
        let iv = NSImageView(frame: NSRect(x: x + (width - 26) / 2, y: y + 34, width: 26, height: 26))
        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        iv.contentTintColor = .controlAccentColor
        iv.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(iv)

        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: x, y: y - 6, width: width, height: 32)
        view.addSubview(label)
    }

    /// Show only permissions still needed. When all are granted, show a single "all set" line.
    private func rebuildPermissions() {
        permissionsBox.subviews.forEach { $0.removeFromSuperview() }
        let boxW = permissionsBox.bounds.width
        var y = permissionsBox.bounds.height - 24

        let screenOK = CGPreflightScreenCaptureAccess()
        let axOK = AXIsProcessTrusted()

        if screenOK && axOK {
            let done = NSTextField(labelWithString: "✓ You're all set — permissions granted.")
            done.font = .systemFont(ofSize: 13, weight: .medium)
            done.textColor = .systemGreen
            done.frame = NSRect(x: 0, y: y - 4, width: boxW, height: 20)
            permissionsBox.addSubview(done)
            let hint = NSTextField(labelWithString: "Press Start any time — DemoTape never records on its own.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.frame = NSRect(x: 0, y: y - 26, width: boxW, height: 16)
            permissionsBox.addSubview(hint)
            return
        }

        if !screenOK {
            addPermissionRow(title: "Allow Screen Recording", tag: "required",
                             detail: "Needed to capture your screen.",
                             buttonTitle: "Allow…", action: #selector(allowScreen), y: &y, boxW: boxW)
        }
        if !axOK {
            addPermissionRow(title: "Allow Accessibility", tag: "optional",
                             detail: "Adds keyboard-shortcut badges. You can skip this.",
                             buttonTitle: "Allow…", action: #selector(allowAccessibility), y: &y, boxW: boxW)
        }
    }

    private func addPermissionRow(title: String, tag: String, detail: String, buttonTitle: String,
                                  action: Selector, y: inout CGFloat, boxW: CGFloat) {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.frame = NSRect(x: 0, y: y, width: 220, height: 18)
        permissionsBox.addSubview(t)
        let tagLabel = NSTextField(labelWithString: tag)
        tagLabel.font = .systemFont(ofSize: 10, weight: .medium)
        tagLabel.textColor = (tag == "required") ? .systemOrange : .tertiaryLabelColor
        tagLabel.frame = NSRect(x: 224, y: y + 1, width: 70, height: 14)
        permissionsBox.addSubview(tagLabel)

        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.frame = NSRect(x: 0, y: y - 18, width: boxW - 130, height: 16)
        permissionsBox.addSubview(d)

        let btn = NSButton(title: buttonTitle, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: boxW - 120, y: y - 12, width: 120, height: 30)
        permissionsBox.addSubview(btn)
        y -= 52
    }

    @objc private func allowScreen() {
        _ = CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.rebuildPermissions() }
    }
    @objc private func allowAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.rebuildPermissions() }
    }

    @objc private func finish() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate(); refreshTimer = nil
        Settings.didCompleteOnboarding = true
        onFinish?()
        window = nil
    }
}
