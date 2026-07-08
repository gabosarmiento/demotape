import AppKit
import AVFoundation

/// Small window to publish the latest styled recording as lightweight, web-ready MP4s.
/// Select one or more height tiers (with a live total-size estimate); it writes an mp4
/// per tier plus a poster and a responsive `<video>` embed into a `<name>-web` folder.
@available(macOS 12.3, *)
final class WebPublishController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var estimateLabel: NSTextField!
    private var exportButton: NSButton!
    private var source: URL?
    private var duration: Double = 0
    private var selected: Set<Int> = []

    func show() {
        guard let styled = Self.latestStyled() else {
            let a = NSAlert()
            a.messageText = "Nothing to publish yet"
            a.informativeText = "Record something first — Web Publish works on your latest styled recording."
            a.runModal()
            return
        }
        source = styled
        duration = CMTimeGetSeconds(AVAsset(url: styled).duration)
        selected = Set(Settings.publishTiers.filter { Transcoder.tiers.contains($0) })
        if selected.isEmpty { selected = [540] }

        let w: CGFloat = 460, h: CGFloat = 260
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Web Publish"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let src = NSTextField(labelWithString: "Source: \(styled.lastPathComponent)")
        src.font = .systemFont(ofSize: 11)
        src.textColor = .secondaryLabelColor
        src.frame = NSRect(x: 20, y: h - 40, width: w - 40, height: 18)
        content.addSubview(src)

        let title = NSTextField(labelWithString: "Quality (select one or more)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: h - 74, width: 300, height: 20)
        content.addSubview(title)

        // Tier checkboxes.
        let boxW: CGFloat = 100
        for (i, tier) in Transcoder.tiers.enumerated() {
            let box = NSButton(checkboxWithTitle: "\(tier)p", target: self, action: #selector(toggleTier(_:)))
            box.tag = tier
            box.state = selected.contains(tier) ? .on : .off
            box.frame = NSRect(x: 20 + CGFloat(i) * boxW, y: h - 108, width: boxW, height: 24)
            content.addSubview(box)
        }

        estimateLabel = NSTextField(labelWithString: "")
        estimateLabel.font = .systemFont(ofSize: 13)
        estimateLabel.frame = NSRect(x: 20, y: h - 146, width: w - 40, height: 20)
        content.addSubview(estimateLabel)

        let note = NSTextField(wrappingLabelWithString: "Use 720p only when the demo has small UI text or code. Selecting several tiers builds a responsive <video> that serves the right size per screen.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: 62, width: w - 40, height: 44)
        content.addSubview(note)

        exportButton = NSButton(title: "Export", target: self, action: #selector(export))
        exportButton.bezelStyle = .rounded
        exportButton.keyEquivalent = "\r"
        exportButton.frame = NSRect(x: w - 130, y: 18, width: 110, height: 32)
        content.addSubview(exportButton)

        window.contentView = content
        self.window = window
        updateEstimate()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleTier(_ sender: NSButton) {
        if sender.state == .on { selected.insert(sender.tag) } else { selected.remove(sender.tag) }
        Settings.publishTiers = Array(selected).sorted()
        updateEstimate()
    }

    private func updateEstimate() {
        guard !selected.isEmpty else {
            estimateLabel.stringValue = "Select at least one quality."
            exportButton?.isEnabled = false
            return
        }
        exportButton?.isEnabled = true
        let total = selected.reduce(0) { $0 + Transcoder.estimatedBytes(duration: duration, height: $1) }
        let mb = Double(total) / 1_000_000
        let tiersText = selected.sorted().map { "\($0)p" }.joined(separator: ", ")
        estimateLabel.stringValue = String(format: "≈ %.1f MB total  ·  %@  ·  %.0fs", mb, tiersText, duration)
    }

    @objc private func export() {
        guard let source = source, !selected.isEmpty else { return }
        exportButton.isEnabled = false
        exportButton.title = "Exporting…"
        let heights = Array(selected)
        DispatchQueue.global(qos: .userInitiated).async {
            let folder = Self.publish(source: source, heights: heights)
            DispatchQueue.main.async {
                if let folder = folder {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                    self.window?.close()
                } else {
                    self.exportButton.isEnabled = true
                    self.exportButton.title = "Export"
                    let a = NSAlert(); a.messageText = "Export failed"; a.runModal()
                }
            }
        }
    }

    /// Produces `<name>-web/` with an mp4 per tier, a poster, a responsive embed, and a readme.
    private static func publish(source: URL, heights: [Int]) -> URL? {
        let base = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".styled", with: "")
        let folder = source.deletingLastPathComponent().appendingPathComponent("\(base)-web", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let t = Transcoder()
        let sorted = heights.sorted()
        for h in sorted {
            do {
                try t.transcode(input: source, to: folder.appendingPathComponent("demo-\(h)p.mp4"), height: h)
            } catch {
                Log.write("WebPublish tier \(h) failed: \(error.localizedDescription)")
                return nil
            }
        }
        t.savePoster(from: source, to: folder.appendingPathComponent("poster.jpg"),
                     maxHeight: sorted.max() ?? 540)

        // Responsive <video>: largest source first with media queries, smallest as fallback.
        let breakpoints: [Int: Int] = [720: 1000, 540: 760, 480: 560, 360: 400]
        let desc = sorted.sorted(by: >)
        var sources = ""
        for (i, h) in desc.enumerated() {
            let name = "demo-\(h)p.mp4"
            if i < desc.count - 1, let bp = breakpoints[h] {
                sources += "  <source src=\"\(name)\" type=\"video/mp4\" media=\"(min-width: \(bp)px)\">\n"
            } else {
                sources += "  <source src=\"\(name)\" type=\"video/mp4\">\n"
            }
        }
        let embed = """
        <video controls muted loop playsinline preload="metadata" poster="poster.jpg" width="100%">
        \(sources)</video>
        """
        try? embed.write(to: folder.appendingPathComponent("embed.html"), atomically: true, encoding: .utf8)

        let fileList = desc.map { "demo-\($0)p.mp4" }.joined(separator: ", ")
        let readme = """
        DemoTape — Web Publish
        =======================
        Files: \(fileList)   H.264 High + AAC, MP4 faststart. Lightweight, fast-loading.
        poster.jpg   First-frame thumbnail for <video poster="…">.
        embed.html   Responsive <video> snippet for your page (kiff.dev). Muted + loop = autoplay-friendly.

        Uploading to X / LinkedIn: upload the largest mp4 directly — they re-encode it.
        Hosting on your site: upload all files and use embed.html (serves the right size per screen).
        """
        try? readme.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    static func latestStyled() -> URL? {
        let dir = Paths.outputDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return items.filter { $0.lastPathComponent.hasSuffix(".styled.mp4") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }.first
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
