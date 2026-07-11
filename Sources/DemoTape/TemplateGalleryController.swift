import AppKit

/// A gallery of one-click auto-edit templates applied to the latest recording. Pick one and
/// DemoTape re-edits the styled master into a richer video (intro, transitions, rhythm, outro).
@available(macOS 12.3, *)
final class TemplateGalleryController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let master: URL
    private var applyButtons: [NSButton] = []
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!

    init(master: URL) { self.master = master }

    func show() {
        let w: CGFloat = 580, h: CGFloat = 560
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Templates"
        win.isReleasedWhenClosed = false
        win.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let header = NSTextField(labelWithString: "Auto-edit templates")
        header.font = .systemFont(ofSize: 16, weight: .semibold)
        header.frame = NSRect(x: 24, y: h - 44, width: w - 48, height: 22)
        content.addSubview(header)
        let sub = NSTextField(labelWithString: "Pick a look — DemoTape re-edits your latest recording. Your original is kept.")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 24, y: h - 64, width: w - 48, height: 16)
        content.addSubview(sub)

        // Scrollable list.
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 64, width: w - 32, height: h - 64 - 76))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let rowH: CGFloat = 82
        let templates = VideoTemplate.catalog
        let docH = CGFloat(templates.count) * rowH
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(docH, scroll.contentSize.height)))
        let dw = scroll.contentSize.width

        applyButtons.removeAll()
        for (i, t) in templates.enumerated() {
            let y = doc.frame.height - CGFloat(i + 1) * rowH
            let card = NSView(frame: NSRect(x: 0, y: y, width: dw, height: rowH - 10))
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
            card.layer?.cornerRadius = 8

            let name = NSTextField(labelWithString: t.name)
            name.font = .systemFont(ofSize: 14, weight: .semibold)
            name.frame = NSRect(x: 16, y: rowH - 10 - 30, width: 240, height: 20)
            card.addSubview(name)

            let tags = NSTextField(labelWithString: t.tags.joined(separator: " · "))
            tags.font = .systemFont(ofSize: 10, weight: .medium)
            tags.textColor = .tertiaryLabelColor
            tags.frame = NSRect(x: 16 + 240, y: rowH - 10 - 28, width: 200, height: 16)
            card.addSubview(tags)

            let persona = NSTextField(wrappingLabelWithString: t.persona)
            persona.font = .systemFont(ofSize: 11)
            persona.textColor = .secondaryLabelColor
            persona.frame = NSRect(x: 16, y: 8, width: dw - 32 - 110, height: 30)
            card.addSubview(persona)

            let apply = NSButton(title: "Apply", target: self, action: #selector(applyTemplate(_:)))
            apply.bezelStyle = .rounded
            apply.tag = i
            apply.frame = NSRect(x: dw - 16 - 96, y: (rowH - 10 - 30) / 2, width: 96, height: 30)
            card.addSubview(apply)
            applyButtons.append(apply)

            doc.addSubview(card)
        }
        scroll.documentView = doc
        content.addSubview(scroll)

        spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 22, width: 20, height: 20))
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 50, y: 22, width: w - 50 - 120, height: 18)
        content.addSubview(statusLabel)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: w - 108, y: 16, width: 84, height: 30)
        content.addSubview(close)

        win.contentView = content
        self.window = win
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func applyTemplate(_ sender: NSButton) {
        let template = VideoTemplate.catalog[sender.tag]
        setBusy(true, message: "Rendering “\(template.name)”… 0%")

        let cam = camURL()
        let branding = brandingURL()
        let out = outputURL(for: template)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try TemplateComposer().compose(master: self.master, cam: cam, branding: branding,
                                               template: template, to: out) { p in
                    DispatchQueue.main.async {
                        self.statusLabel.stringValue = "Rendering “\(template.name)”… \(Int(p * 100))%"
                    }
                }
                DispatchQueue.main.async {
                    self.setBusy(false, message: "Saved \(out.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false, message: "")
                    let alert = NSAlert()
                    alert.messageText = "Couldn't apply “\(template.name)”"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private func setBusy(_ busy: Bool, message: String) {
        applyButtons.forEach { $0.isEnabled = !busy }
        statusLabel.stringValue = message
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: - Paths

    /// Core recording name without the ".styled"/".mp4" suffixes.
    private func coreName() -> String {
        var base = master.deletingPathExtension().lastPathComponent   // drops .mp4
        if base.hasSuffix(".styled") { base = String(base.dropLast(".styled".count)) }
        return base
    }

    private func camURL() -> URL? {
        let candidate = master.deletingLastPathComponent().appendingPathComponent(coreName() + ".cam.mov")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func brandingURL() -> URL? {
        guard Settings.brandingEnabled, !Settings.brandingImagePath.isEmpty,
              FileManager.default.fileExists(atPath: Settings.brandingImagePath) else { return nil }
        return URL(fileURLWithPath: Settings.brandingImagePath)
    }

    private func outputURL(for t: VideoTemplate) -> URL {
        master.deletingLastPathComponent().appendingPathComponent("\(coreName())-\(t.id).mp4")
    }

    @objc private func closeWindow() { window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil }
}
