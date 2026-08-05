import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// The Videos window: browse everything you've made in the current recording folder, and publish the
/// latest styled take as lightweight web MP4s.
///
/// It replaced a bare "Export" button that gave no feedback — during a multi-tier export it just read
/// "Exporting…", so a slow run looked hung and closing the window felt like it would interrupt. Now
/// export reports a live bar per tier, the window stays closable (the encode runs in the background and
/// finishes regardless), and every finished file appears in a carousel below with a thumbnail and its
/// name — so the videos you make are actually findable, the way a clipboard/paste bar surfaces items.
@available(macOS 12.3, *)
final class WebPublishController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var estimateLabel: NSTextField!
    private var exportButton: NSButton!
    private var openFolderButton: NSButton!
    /// The `<name>-web/` bundle produced by this session's export. nil until an export finishes;
    /// drives both the header "Open Folder" button and which folder the carousel shows.
    private var exportedFolder: URL?
    private var source: URL?
    private var duration: Double = 0
    private var selected: Set<Int> = []
    private var exporting = false

    private var sourceLabel: NSTextField!
    private var gifCheckbox: NSButton!
    private var gifQualitySeg: NSSegmentedControl!
    private var gifDesc: NSTextField!
    private var progressStack: NSStackView!
    private var progressRows: [String: (bar: NSProgressIndicator, label: NSTextField)] = [:]
    private var carousel: VideoCarousel!

    private let gifPresets: [(name: String, width: Int, fps: Int, blurb: String)] = [
        ("Smaller",  360,  8, "Tiny file — best for page inserts"),
        ("Balanced", 480, 10, "Recommended for most READMEs"),
        ("Sharp",    640, 12, "Crisp detail — larger file")
    ]

    private let W: CGFloat = 640
    private let H: CGFloat = 560

    func show() {
        // Default to the current working file (the latest processed cut — voiceover/tight/captioned),
        // not the raw styled master, so Web Export offers what the user actually finished.
        let styled = RecordingLayout.latestSource() ?? Self.latestStyled()
        source = styled
        if let s = styled { duration = CMTimeGetSeconds(AVAsset(url: s).duration) }
        selected = Set(Settings.publishTiers.filter { Transcoder.tiers.contains($0) })
        if selected.isEmpty { selected = [540] }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Web Export"
        Theme.style(window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        content.autoresizingMask = [.width, .height]

        buildPublishControls(in: content)
        buildProgressArea(in: content)
        buildCarousel(in: content)

        window.contentView = content
        self.window = window
        updateEstimate()
        refreshCarousel()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Publish controls (top)

    private func buildPublishControls(in content: NSView) {
        let top = H - 40
        let name = source?.lastPathComponent ?? "no styled recording yet"
        let src = NSTextField(labelWithString: "Publish: \(name)")
        src.font = .systemFont(ofSize: 11); src.textColor = .secondaryLabelColor
        src.lineBreakMode = .byTruncatingMiddle
        src.frame = NSRect(x: 20, y: top, width: W - 40 - 84, height: 18)
        content.addSubview(src); sourceLabel = src

        let change = NSButton(title: "Change…", target: self, action: #selector(changeSource))
        change.bezelStyle = .rounded; change.controlSize = .small
        change.frame = NSRect(x: W - 20 - 76, y: top - 3, width: 76, height: 22)
        content.addSubview(change)

        let title = NSTextField(labelWithString: "Web quality (pick one or more)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: top - 32, width: 320, height: 20)
        content.addSubview(title)

        let boxW: CGFloat = 92
        for (i, tier) in Transcoder.tiers.enumerated() {
            let box = NSButton(checkboxWithTitle: "\(tier)p", target: self, action: #selector(toggleTier(_:)))
            box.tag = tier; box.state = selected.contains(tier) ? .on : .off
            box.frame = NSRect(x: 20 + CGFloat(i) * boxW, y: top - 62, width: boxW, height: 24)
            content.addSubview(box)
        }

        gifCheckbox = NSButton(checkboxWithTitle: "  Looping GIF", target: self, action: #selector(gifToggled))
        gifCheckbox.state = Settings.publishGIF ? .on : .off
        gifCheckbox.frame = NSRect(x: 20 + CGFloat(Transcoder.tiers.count) * boxW, y: top - 62, width: 120, height: 24)
        content.addSubview(gifCheckbox)

        estimateLabel = NSTextField(labelWithString: "")
        estimateLabel.font = .systemFont(ofSize: 12); estimateLabel.textColor = .secondaryLabelColor
        estimateLabel.frame = NSRect(x: 20, y: top - 90, width: W - 40 - 130, height: 18)
        content.addSubview(estimateLabel)

        gifQualitySeg = NSSegmentedControl(labels: gifPresets.map { $0.name },
                                           trackingMode: .selectOne, target: self, action: #selector(gifQualityChanged))
        gifQualitySeg.frame = NSRect(x: 20, y: top - 118, width: 260, height: 24)
        gifQualitySeg.selectedSegment = gifPresets.firstIndex { $0.name == Settings.gifQuality } ?? 1
        gifQualitySeg.isHidden = gifCheckbox.state != .on
        content.addSubview(gifQualitySeg)

        exportButton = NSButton(title: "Export web files", target: self, action: #selector(export))
        exportButton.bezelStyle = .rounded; exportButton.keyEquivalent = "\r"
        Theme.stylePrimary(exportButton)
        exportButton.frame = NSRect(x: W - 20 - 150, y: top - 120, width: 150, height: 30)
        exportButton.isEnabled = source != nil
        content.addSubview(exportButton)
    }

    @objc private func openExportedFolder() {
        guard let folder = exportedFolder else { return }
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Live progress (middle, hidden until export)

    private func buildProgressArea(in content: NSView) {
        progressStack = NSStackView(frame: NSRect(x: 20, y: H - 300, width: W - 40, height: 120))
        progressStack.orientation = .vertical
        progressStack.alignment = .leading
        progressStack.spacing = 6
        progressStack.isHidden = true
        content.addSubview(progressStack)
    }

    private func progressRow(_ key: String, label: String) -> (bar: NSProgressIndicator, label: NSTextField) {
        if let existing = progressRows[key] { return existing }
        let row = NSView(frame: NSRect(x: 0, y: 0, width: W - 40, height: 22))
        let name = NSTextField(labelWithString: label)
        name.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        name.frame = NSRect(x: 0, y: 2, width: 120, height: 16)
        row.addSubview(name)
        let bar = NSProgressIndicator(frame: NSRect(x: 128, y: 4, width: W - 40 - 128, height: 12))
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1; bar.style = .bar
        row.addSubview(bar)
        row.widthAnchor.constraint(equalToConstant: W - 40).isActive = true
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        progressStack.addArrangedSubview(row)
        let pair = (bar, name)
        progressRows[key] = pair
        return pair
    }

    // MARK: - Carousel (bottom)

    private func buildCarousel(in content: NSView) {
        let header = NSTextField(labelWithString: "In this folder")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.frame = NSRect(x: 20, y: 190, width: 300, height: 20)
        content.addSubview(header)

        // Reveal the exported bundle, aligned with the "In this folder" header. Hidden until an
        // export finishes — before that there's no bundle to open, so a button would be noise.
        openFolderButton = NSButton(title: "Open Folder", target: self, action: #selector(openExportedFolder))
        openFolderButton.bezelStyle = .rounded
        openFolderButton.frame = NSRect(x: W - 20 - 130, y: 185, width: 130, height: 28)
        openFolderButton.isHidden = true
        content.addSubview(openFolderButton)

        let hint = NSTextField(labelWithString: "Click a video to reveal it in Finder.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 172, width: W - 40, height: 16)
        content.addSubview(hint)

        carousel = VideoCarousel(frame: NSRect(x: 12, y: 16, width: W - 24, height: 150))
        carousel.autoresizingMask = [.width]
        carousel.onSelect = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        content.addSubview(carousel)
    }

    private func refreshCarousel() {
        // After an export, show the files that were just generated (the `-web` bundle), so they're
        // one click away — otherwise the source recording's folder.
        let folder = exportedFolder
            ?? (source ?? RecordingLayout.latestSource() ?? Self.latestStyled())?.deletingLastPathComponent()
            ?? RecordingLayout.recordingFolders().first
            ?? Paths.outputDirectory
        carousel?.setVideos(Self.videosIn(folder))
    }

    /// Video files directly in `folder`, newest first (the flat list a user sees in Finder).
    static func videosIn(_ folder: URL) -> [URL] {
        let exts: Set<String> = ["mp4", "mov", "m4v"]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    // MARK: - Actions

    @objc private func toggleTier(_ sender: NSButton) {
        if sender.state == .on { selected.insert(sender.tag) } else { selected.remove(sender.tag) }
        Settings.publishTiers = Array(selected).sorted()
        updateEstimate()
    }

    @objc private func changeSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.directoryURL = source?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url
        duration = CMTimeGetSeconds(AVAsset(url: url).duration)
        sourceLabel.stringValue = "Publish: \(url.lastPathComponent)"
        sourceLabel.toolTip = url.path
        exportButton.isEnabled = !exporting
        exportedFolder = nil                 // new source: no export yet, hide the button and
        openFolderButton?.isHidden = true    // show that source's own folder again
        updateEstimate(); refreshCarousel()
    }

    @objc private func gifToggled() {
        Settings.publishGIF = (gifCheckbox.state == .on)
        gifQualitySeg.isHidden = gifCheckbox.state != .on
        updateEstimate()
    }
    @objc private func gifQualityChanged() {
        Settings.gifQuality = gifPresets[gifQualitySeg.indexOfSelectedItem].name
    }

    private func updateEstimate() {
        let gifOn = gifCheckbox?.state == .on
        exportButton?.isEnabled = source != nil && !exporting && (!selected.isEmpty || gifOn)
        guard let _ = source else { estimateLabel?.stringValue = "Record something to publish it."; return }
        guard !selected.isEmpty else {
            estimateLabel.stringValue = gifOn ? "GIF only." : "Pick at least one quality (or a GIF)."
            return
        }
        let total = selected.reduce(0) { $0 + Transcoder.estimatedBytes(duration: duration, height: $1) }
        let mb = Double(total) / 1_000_000
        let tiers = selected.sorted().map { "\($0)p" }.joined(separator: ", ")
        estimateLabel.stringValue = String(format: "≈ %.1f MB  ·  %@  ·  %.0fs", mb, tiers, duration)
    }

    @objc private func export() {
        guard let source = source, !exporting else { return }
        let gifOn = gifCheckbox.state == .on
        guard !selected.isEmpty || gifOn else { return }

        exporting = true
        exportButton.isEnabled = false
        exportButton.title = "Exporting…"
        // Prepare a progress row per output so the user sees the whole plan at once.
        progressRows.forEach { $0.value.bar.removeFromSuperview() }
        progressStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        progressRows.removeAll()
        progressStack.isHidden = false
        for tier in selected.sorted() { _ = progressRow("\(tier)p", label: "\(tier)p") }
        if gifOn { _ = progressRow("GIF", label: "GIF") }

        let heights = Array(selected)
        let preset = gifPresets[gifQualitySeg.indexOfSelectedItem]
        Settings.gifQuality = preset.name

        // The encode runs on a background queue and is a plain function — it finishes and writes every
        // file even if this window is closed. UI callbacks are weak, so closing simply stops updating.
        let progress = WebPublish.Progress(
            stage: { [weak self] label, fraction in
                DispatchQueue.main.async { self?.progressRows[label]?.bar.doubleValue = fraction }
            },
            produced: { [weak self] url in
                DispatchQueue.main.async { self?.refreshCarousel() }
            })

        DispatchQueue.global(qos: .userInitiated).async {
            let folder = WebPublish.export(source: source, heights: heights,
                                           gif: gifOn, gifWidth: preset.width, gifFps: preset.fps,
                                           progress: progress)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.window != nil else { return }
                self.exporting = false
                self.exportButton.title = "Export web files"
                self.updateEstimate()
                self.refreshCarousel()
                if let folder = folder {
                    self.estimateLabel.stringValue = "Done — \(folder.lastPathComponent) is in this folder."
                    self.exportedFolder = folder
                    self.openFolderButton.isHidden = false
                    self.openFolderButton.toolTip = folder.path
                    self.refreshCarousel()      // now shows the generated web files, clickable
                } else {
                    let a = NSAlert(); a.messageText = "Export failed"; a.runModal()
                }
            }
        }
    }

    static func latestStyled() -> URL? { RecordingLayout.latestFinal(suffix: ".styled.mp4") }

    func windowWillClose(_ notification: Notification) { window = nil }
}

/// A horizontal strip of video cards: thumbnail + filename. Thumbnails are generated off the main
/// thread and cached, so scanning a folder full of takes doesn't stall the window.
@available(macOS 12.3, *)
final class VideoCarousel: NSView {
    var onSelect: ((URL) -> Void)?
    private let scroll = NSScrollView()
    private let strip = NSStackView()
    private static var thumbCache: [String: NSImage] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        strip.orientation = .horizontal
        strip.alignment = .top
        strip.spacing = 12
        strip.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        strip.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            strip.topAnchor.constraint(equalTo: doc.topAnchor),
            strip.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalToConstant: frame.height - 4),
        ])
        scroll.documentView = doc
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setVideos(_ urls: [URL]) {
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if urls.isEmpty {
            let empty = NSTextField(labelWithString: "No videos in this folder yet.")
            empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor
            strip.addArrangedSubview(empty)
            return
        }
        for url in urls { strip.addArrangedSubview(makeCard(url)) }
    }

    private func makeCard(_ url: URL) -> NSView {
        let card = ClickableCard(url: url) { [weak self] in self?.onSelect?(url) }
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 168).isActive = true

        let thumb = NSImageView(frame: .zero)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        card.addSubview(thumb)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 11)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 2
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: card.topAnchor),
            thumb.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            thumb.heightAnchor.constraint(equalToConstant: 94),
            name.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 5),
            name.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            name.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        card.toolTip = url.lastPathComponent
        loadThumb(url, into: thumb)
        return card
    }

    private func loadThumb(_ url: URL, into view: NSImageView) {
        let key = url.path
        if let cached = Self.thumbCache[key] { view.image = cached; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 336, height: 188)
            let t = CMTime(seconds: min(1.0, CMTimeGetSeconds(asset.duration) * 0.2), preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async { Self.thumbCache[key] = img; view.image = img }
        }
    }
}

/// A card that reveals its video on click and gives a pointing-hand cursor.
@available(macOS 12.3, *)
private final class ClickableCard: NSView {
    private let action: () -> Void
    init(url: URL, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { action() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
