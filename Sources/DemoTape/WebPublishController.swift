import AppKit
import AVFoundation
import UniformTypeIdentifiers

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

    private var sourceLabel: NSTextField!
    private var gifCheckbox: NSButton!
    private var gifQualitySeg: NSSegmentedControl!
    private var gifDesc: NSTextField!
    /// Plain-language GIF presets. The encoder frame-diffs (transparent unchanged pixels), so these
    /// stay light; "Smaller" is tuned for dropping a tiny loop into a page/README.
    private let gifPresets: [(name: String, width: Int, fps: Int, blurb: String)] = [
        ("Smaller",  360,  8, "Tiny file — best for page inserts"),
        ("Balanced", 480, 10, "Recommended for most READMEs"),
        ("Sharp",    640, 12, "Crisp detail — larger file")
    ]

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

        let w: CGFloat = 460, h: CGFloat = 344
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Web Publish"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let src = NSTextField(labelWithString: "Source: \(styled.lastPathComponent)")
        src.font = .systemFont(ofSize: 11)
        src.textColor = .secondaryLabelColor
        src.lineBreakMode = .byTruncatingMiddle
        src.frame = NSRect(x: 20, y: h - 40, width: w - 40 - 78, height: 18)
        content.addSubview(src)
        self.sourceLabel = src

        let changeButton = NSButton(title: "Change…", target: self, action: #selector(changeSource))
        changeButton.bezelStyle = .rounded
        changeButton.controlSize = .small
        changeButton.frame = NSRect(x: w - 20 - 72, y: h - 44, width: 72, height: 22)
        content.addSubview(changeButton)

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
        note.frame = NSRect(x: 20, y: h - 190, width: w - 40, height: 44)
        content.addSubview(note)

        // --- Animated GIF ---
        let gifTitle = NSTextField(labelWithString: "Animated GIF")
        gifTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        gifTitle.frame = NSRect(x: 20, y: 118, width: 200, height: 20)
        content.addSubview(gifTitle)

        gifCheckbox = NSButton(checkboxWithTitle: "  Also export a looping GIF (for READMEs)",
                               target: self, action: #selector(gifToggled))
        gifCheckbox.state = Settings.publishGIF ? .on : .off
        gifCheckbox.frame = NSRect(x: 20, y: 96, width: w - 40, height: 22)
        content.addSubview(gifCheckbox)

        gifQualitySeg = NSSegmentedControl(labels: gifPresets.map { $0.name },
                                           trackingMode: .selectOne,
                                           target: self, action: #selector(gifQualityChanged))
        gifQualitySeg.frame = NSRect(x: 20, y: 62, width: 300, height: 26)
        gifQualitySeg.selectedSegment = gifPresets.firstIndex { $0.name == Settings.gifQuality } ?? 1
        content.addSubview(gifQualitySeg)

        gifDesc = NSTextField(labelWithString: "")
        gifDesc.font = .systemFont(ofSize: 11); gifDesc.textColor = .secondaryLabelColor
        gifDesc.frame = NSRect(x: 20, y: 40, width: w - 40, height: 16)
        content.addSubview(gifDesc)
        updateGifDesc()

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

    @objc private func changeSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = source?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url
        duration = CMTimeGetSeconds(AVAsset(url: url).duration)
        sourceLabel.stringValue = "Source: \(url.lastPathComponent)"
        sourceLabel.toolTip = url.path
        updateEstimate()
    }

    @objc private func gifToggled() { Settings.publishGIF = (gifCheckbox.state == .on); updateEstimate() }
    @objc private func gifQualityChanged() {
        Settings.gifQuality = gifPresets[gifQualitySeg.indexOfSelectedItem].name
        updateGifDesc()
    }
    private func updateGifDesc() {
        gifDesc.stringValue = gifPresets[max(0, gifQualitySeg.indexOfSelectedItem)].blurb
    }

    private func updateEstimate() {
        let gifOn = gifCheckbox?.state == .on
        exportButton?.isEnabled = !selected.isEmpty || gifOn
        guard !selected.isEmpty else {
            estimateLabel.stringValue = gifOn ? "GIF only." : "Select at least one quality (or a GIF)."
            return
        }
        let total = selected.reduce(0) { $0 + Transcoder.estimatedBytes(duration: duration, height: $1) }
        let mb = Double(total) / 1_000_000
        let tiersText = selected.sorted().map { "\($0)p" }.joined(separator: ", ")
        estimateLabel.stringValue = String(format: "≈ %.1f MB (mp4)  ·  %@  ·  %.0fs", mb, tiersText, duration)
    }

    @objc private func export() {
        guard let source = source else { return }
        let gifOn = gifCheckbox.state == .on
        guard !selected.isEmpty || gifOn else { return }
        exportButton.isEnabled = false
        exportButton.title = "Exporting…"
        let heights = Array(selected)
        let preset = gifPresets[gifQualitySeg.indexOfSelectedItem]
        Settings.gifQuality = preset.name
        DispatchQueue.global(qos: .userInitiated).async {
            let folder = WebPublish.export(source: source, heights: heights,
                                           gif: gifOn, gifWidth: preset.width, gifFps: preset.fps)
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

    static func latestStyled() -> URL? {
        RecordingLayout.latestFinal(suffix: ".styled.mp4")
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
