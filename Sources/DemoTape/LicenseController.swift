import AppKit

/// Small window where a recipient pastes and activates a license key. Verification is fully local
/// (against the embedded public key) — no account, no network.
@available(macOS 12.3, *)
final class LicenseController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var statusLabel: NSTextField!
    private var keyView: NSTextView!
    private var activateButton: NSButton!
    private var removeButton: NSButton!
    private var message: NSTextField!

    func show() {
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w: CGFloat = 460, h: CGFloat = 300
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DemoTape License"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let title = NSTextField(labelWithString: "License")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 20, y: h - 44, width: w - 40, height: 22)
        content.addSubview(title)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.frame = NSRect(x: 20, y: h - 68, width: w - 40, height: 18)
        content.addSubview(statusLabel)

        let prompt = NSTextField(labelWithString: "Paste your license key:")
        prompt.font = .systemFont(ofSize: 12)
        prompt.textColor = .secondaryLabelColor
        prompt.frame = NSRect(x: 20, y: h - 98, width: w - 40, height: 16)
        content.addSubview(prompt)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 92, width: w - 40, height: 108))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        keyView = NSTextView(frame: scroll.bounds)
        keyView.isRichText = false
        keyView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        keyView.textContainerInset = NSSize(width: 6, height: 6)
        keyView.isAutomaticQuoteSubstitutionEnabled = false
        scroll.documentView = keyView
        content.addSubview(scroll)

        message = NSTextField(labelWithString: "")
        message.font = .systemFont(ofSize: 11)
        message.frame = NSRect(x: 20, y: 62, width: w - 40, height: 18)
        content.addSubview(message)

        activateButton = NSButton(title: "Activate", target: self, action: #selector(activate))
        activateButton.bezelStyle = .rounded
        activateButton.keyEquivalent = "\r"
        activateButton.frame = NSRect(x: w - 20 - 110, y: 18, width: 110, height: 32)
        content.addSubview(activateButton)

        removeButton = NSButton(title: "Remove License", target: self, action: #selector(remove))
        removeButton.bezelStyle = .rounded
        removeButton.frame = NSRect(x: 20, y: 18, width: 150, height: 32)
        content.addSubview(removeButton)

        window.contentView = content
        self.window = window
        refresh()

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        if let info = License.current() {
            statusLabel.stringValue = "✓ Licensed to \(info.name)"
            statusLabel.textColor = .systemGreen
            removeButton.isHidden = false
        } else if License.publicKeyBase64.isEmpty {
            statusLabel.stringValue = "Licensing isn't set up in this build."
            statusLabel.textColor = .secondaryLabelColor
            removeButton.isHidden = true
        } else {
            statusLabel.stringValue = "Not activated"
            statusLabel.textColor = .secondaryLabelColor
            removeButton.isHidden = true
        }
    }

    @objc private func activate() {
        let key = keyView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if let info = License.activate(key) {
            message.textColor = .systemGreen
            message.stringValue = "Activated — welcome, \(info.name)."
            keyView.string = ""
            refresh()
        } else {
            message.textColor = .systemRed
            message.stringValue = "That license key isn't valid."
        }
    }

    @objc private func remove() {
        License.deactivate()
        message.stringValue = ""
        refresh()
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
