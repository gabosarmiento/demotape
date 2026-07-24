import AppKit
import AVKit

/// "Explain to AI" window. Instead of rendering a polished video, this **analyzes** a short
/// recording: it transcribes the narration, reads the clicks, grabs keyframes, and asks the model
/// to author a structured brief. The layout is purpose-built (not the video-preview base): the
/// source clip on the left with an **Analyze** button, and on the right a switch between the
/// **Kiro / Claude Code** prompt, the **Web chat** prompt, and the **Files** that were created
/// (folder path + a carousel of the captured screenshots). Footer: Download Zip + Reveal in Finder.
@available(macOS 12.3, *)
final class AIBriefActionController: NSObject, NSWindowDelegate {

    private var source: URL
    private let stt: Captions.Config
    private let chat: AIBrief.Config

    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private var isCancelled = false
    private var isRevealed = false
    private var lastBuild: AIBriefBuilder.Result?

    // Left column
    private var sourceNameField: NSTextField!
    private var sourcePlayer: AVPlayerView!
    private var analyzeButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!

    // Right column
    private var rightColView: NSStackView!
    private var segmented: NSSegmentedControl!
    private var placeholderLabel: NSTextField!
    private var kiroPanel: NSView!
    private var webPanel: NSView!
    private var filesPanel: NSView!
    private var kiroText: NSTextView!
    private var webText: NSTextView!
    private var carouselStack: NSStackView!
    private var filesListStack: NSStackView!
    private var folderPathLabel: NSTextField!

    // Footer
    private var copyKiroButton: NSButton!
    private var copyWebButton: NSButton!
    private var downloadZipButton: NSButton!
    private var revealButton: NSButton!

    init(source: URL, stt: Captions.Config, chat: AIBrief.Config) {
        self.source = source
        self.stt = stt
        self.chat = chat
        super.init()
    }

    // MARK: - Presentation

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Stage A ("just the video + the Analyze CTA"): open compact, with the Handoff column
        // hidden. Analyzing animates the window wider to reveal it (see `revealHandoff`).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.compactWidth, height: Self.compactHeight),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Explain to AI"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContent()
        self.window = window

        rightColView.isHidden = true      // stage A
        reloadSource()
        showPanel(index: 0)
        setControlsEnabled(false)

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // Compact (video + CTA only) vs. revealed (video + Handoff) content sizes. The Handoff column
    // has a fixed width, so the text canvas never reflows when a brief loads into it.
    private static let compactWidth: CGFloat = 460
    private static let compactHeight: CGFloat = 490
    private static let fullWidth: CGFloat = 1040
    private static let fullHeight: CGFloat = 700

    /// Animates from stage A to the revealed two-column layout (once).
    private func revealHandoff(animated: Bool) {
        guard !isRevealed, let window = window else { return }
        isRevealed = true
        rightColView.isHidden = false
        let content = NSRect(origin: .zero, size: NSSize(width: Self.fullWidth, height: Self.fullHeight))
        var frame = window.frameRect(forContentRect: content)
        let old = window.frame
        frame.origin.x = old.midX - frame.width / 2   // keep centered horizontally
        frame.origin.y = old.maxY - frame.height      // keep the top edge fixed
        window.setFrame(frame, display: true, animate: animated)
    }

    /// Collapses back to stage A (used when the user picks a different source).
    private func collapseHandoff() {
        guard isRevealed, let window = window else { return }
        isRevealed = false
        rightColView.isHidden = true
        let content = NSRect(origin: .zero, size: NSSize(width: Self.compactWidth, height: Self.compactHeight))
        var frame = window.frameRect(forContentRect: content)
        let old = window.frame
        frame.origin.x = old.midX - frame.width / 2
        frame.origin.y = old.maxY - frame.height
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let root = NSView()
        let inset: CGFloat = 20

        // Header: file name + Change…
        sourceNameField = NSTextField(labelWithString: "")
        sourceNameField.font = .systemFont(ofSize: 13, weight: .medium)
        sourceNameField.lineBreakMode = .byTruncatingMiddle
        sourceNameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let changeButton = NSButton(title: "Change…", target: self, action: #selector(changeSource))
        changeButton.bezelStyle = .rounded

        // Left: source player + Analyze + status.
        sourcePlayer = AVPlayerView()
        sourcePlayer.controlsStyle = .inline
        sourcePlayer.videoGravity = .resizeAspect
        sourcePlayer.wantsLayer = true
        sourcePlayer.layer?.backgroundColor = NSColor.black.cgColor
        sourcePlayer.layer?.cornerRadius = 6
        sourcePlayer.translatesAutoresizingMaskIntoConstraints = false
        sourcePlayer.heightAnchor.constraint(equalToConstant: 250).isActive = true

        analyzeButton = NSButton(title: "Analyze recording", target: self, action: #selector(analyze))
        analyzeButton.bezelStyle = .rounded
        analyzeButton.controlSize = .large
        analyzeButton.keyEquivalent = "\r"

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel = NSTextField(labelWithString: "Click Analyze to transcribe, capture frames, and write the brief.")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .top

        let sourceLabel = NSTextField(labelWithString: "Source")
        sourceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let leftCol = NSStackView(views: [sourceLabel, sourcePlayer, analyzeButton, statusRow])
        leftCol.orientation = .vertical
        leftCol.alignment = .centerX
        leftCol.spacing = 12
        sourcePlayer.widthAnchor.constraint(equalTo: leftCol.widthAnchor).isActive = true

        // Right: segmented switch + panels.
        segmented = NSSegmentedControl(labels: ["Kiro / Claude Code", "Web chat", "Files"],
                                       trackingMode: .selectOne, target: self, action: #selector(segmentChanged))
        segmented.selectedSegment = 0

        let panelHost = NSView()
        panelHost.wantsLayer = true
        panelHost.layer?.borderColor = NSColor.separatorColor.cgColor
        panelHost.layer?.borderWidth = 1
        panelHost.layer?.cornerRadius = 8
        panelHost.translatesAutoresizingMaskIntoConstraints = false

        kiroPanel = makeKiroPanel()
        webPanel = makeWebPanel()
        filesPanel = makeFilesPanel()
        placeholderLabel = NSTextField(labelWithString: "No brief yet — click Analyze.")
        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = .tertiaryLabelColor

        for v in [kiroPanel, webPanel, filesPanel, placeholderLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            panelHost.addSubview(v)
            if v === placeholderLabel {
                NSLayoutConstraint.activate([
                    v.centerXAnchor.constraint(equalTo: panelHost.centerXAnchor),
                    v.centerYAnchor.constraint(equalTo: panelHost.centerYAnchor)
                ])
            } else {
                NSLayoutConstraint.activate([
                    v.topAnchor.constraint(equalTo: panelHost.topAnchor, constant: 10),
                    v.leadingAnchor.constraint(equalTo: panelHost.leadingAnchor, constant: 10),
                    v.trailingAnchor.constraint(equalTo: panelHost.trailingAnchor, constant: -10),
                    v.bottomAnchor.constraint(equalTo: panelHost.bottomAnchor, constant: -10)
                ])
            }
        }

        let rightLabel = NSTextField(labelWithString: "Handoff")
        rightLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        rightColView = NSStackView(views: [rightLabel, segmented, panelHost])
        rightColView.orientation = .vertical
        rightColView.alignment = .leading
        rightColView.spacing = 12
        rightColView.translatesAutoresizingMaskIntoConstraints = false
        rightColView.widthAnchor.constraint(equalToConstant: 560).isActive = true   // fixed → no reflow
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.widthAnchor.constraint(equalTo: rightColView.widthAnchor).isActive = true
        panelHost.widthAnchor.constraint(equalTo: rightColView.widthAnchor).isActive = true

        // Main split, centered so it reads as a single card in stage A (video only) and fills the
        // window once the fixed-width Handoff column is revealed.
        let split = NSStackView(views: [leftCol, rightColView])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 20
        leftCol.translatesAutoresizingMaskIntoConstraints = false
        leftCol.widthAnchor.constraint(equalToConstant: 420).isActive = true

        // Footer: Reveal in Finder sits next to Close (Copy/Download live in their panels).
        revealButton = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealFolder))
        revealButton.bezelStyle = .rounded
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerSpacer, revealButton, closeButton])
        footer.orientation = .horizontal
        footer.spacing = 10

        for v in [sourceNameField, changeButton, split, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            sourceNameField.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            sourceNameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            changeButton.centerYAnchor.constraint(equalTo: sourceNameField.centerYAnchor),
            changeButton.leadingAnchor.constraint(equalTo: sourceNameField.trailingAnchor, constant: 8),
            changeButton.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -inset),

            split.topAnchor.constraint(equalTo: sourceNameField.bottomAnchor, constant: 14),
            split.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            split.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: inset),

            footer.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset)
        ])
        return root
    }

    private func makeTextArea() -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let tv = NSTextView()
        tv.isEditable = false
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        return (scroll, tv)
    }

    private func makeKiroPanel() -> NSView {
        let (scroll, tv) = makeTextArea()
        kiroText = tv
        let hint = NSTextField(wrappingLabelWithString:
            "Paste this into Kiro or Claude Code — it points them at the brief folder on disk, "
            + "so the agent reads BRIEF.md, the screenshots, and the transcript itself.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        copyKiroButton = NSButton(title: "Copy Kiro prompt", target: self, action: #selector(copyKiro))
        copyKiroButton.bezelStyle = .rounded
        let buttonRow = rightAlignedRow(copyKiroButton)

        let stack = NSStackView(views: [scroll, hint, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeWebPanel() -> NSView {
        let (scroll, tv) = makeTextArea()
        webText = tv
        let hint = NSTextField(wrappingLabelWithString:
            "For a browser chat (ChatGPT / Claude) that can't read local files: this inlines the "
            + "brief. Attach the screenshots from the downloaded .zip.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        copyWebButton = NSButton(title: "Copy web prompt", target: self, action: #selector(copyWeb))
        copyWebButton.bezelStyle = .rounded
        let buttonRow = rightAlignedRow(copyWebButton)

        let stack = NSStackView(views: [scroll, hint, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// Wraps a control in a horizontal row that pushes it to the trailing edge.
    private func rightAlignedRow(_ control: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeFilesPanel() -> NSView {
        folderPathLabel = NSTextField(labelWithString: "")
        folderPathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        folderPathLabel.textColor = .secondaryLabelColor
        folderPathLabel.lineBreakMode = .byTruncatingMiddle

        let shotsLabel = NSTextField(labelWithString: "Screenshots")
        shotsLabel.font = .systemFont(ofSize: 11, weight: .semibold)

        // Horizontal carousel of frame thumbnails.
        let carScroll = NSScrollView()
        carScroll.hasHorizontalScroller = true
        carScroll.hasVerticalScroller = false
        carScroll.borderType = .noBorder
        carScroll.drawsBackground = false
        carScroll.translatesAutoresizingMaskIntoConstraints = false
        carScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true

        carouselStack = NSStackView()
        carouselStack.orientation = .horizontal
        carouselStack.spacing = 10
        carouselStack.alignment = .top
        carouselStack.translatesAutoresizingMaskIntoConstraints = false
        carScroll.documentView = carouselStack
        NSLayoutConstraint.activate([
            carouselStack.topAnchor.constraint(equalTo: carScroll.contentView.topAnchor),
            carouselStack.leadingAnchor.constraint(equalTo: carScroll.contentView.leadingAnchor),
            carouselStack.bottomAnchor.constraint(equalTo: carScroll.contentView.bottomAnchor)
        ])

        let filesLabel = NSTextField(labelWithString: "Files")
        filesLabel.font = .systemFont(ofSize: 11, weight: .semibold)

        // The file list sits directly under its header and sizes to its content (only a handful of
        // entries), so it never floats away from the "Files" label.
        filesListStack = NSStackView()
        filesListStack.orientation = .vertical
        filesListStack.alignment = .leading
        filesListStack.spacing = 4
        filesListStack.translatesAutoresizingMaskIntoConstraints = false

        downloadZipButton = NSButton(title: "Download Zip…", target: self, action: #selector(downloadZip))
        downloadZipButton.bezelStyle = .rounded
        let buttonRow = rightAlignedRow(downloadZipButton)

        // A flexible spacer absorbs the leftover height, pinning the content to the top and the
        // button to the bottom — so there's no gap between the screenshots, the files, and the list.
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let stack = NSStackView(views: [folderPathLabel, shotsLabel, carScroll, filesLabel,
                                        filesListStack, bottomSpacer, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        folderPathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        carScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        filesListStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: - Analyze

    @objc private func analyze() {
        guard !chat.apiKey.isEmpty else {
            setStatus("Add your OpenAI-compatible key in AI Settings.", isError: true)
            return
        }
        isCancelled = false
        revealHandoff(animated: true)
        setBusy(true)
        setStatus("Analyzing…", isError: false)
        let src = source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try AIBriefBuilder(stt: self.stt, chat: self.chat).build(for: src) { p in
                    DispatchQueue.main.async {
                        if !self.isCancelled { self.setStatus("Analyzing… \(Int(p * 100))%", isError: false) }
                    }
                }
                DispatchQueue.main.async {
                    guard !self.isCancelled else { return }
                    self.populate(result)
                }
            } catch {
                DispatchQueue.main.async {
                    guard !self.isCancelled else { return }
                    self.setBusy(false)
                    self.setStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func populate(_ result: AIBriefBuilder.Result) {
        lastBuild = result
        kiroText.string = result.agentPrompt
        webText.string = result.webPrompt
        folderPathLabel.stringValue = result.bundleDir.path
        folderPathLabel.toolTip = result.bundleDir.path
        rebuildCarousel(result)
        rebuildFilesList(result)
        setBusy(false)
        setControlsEnabled(true)
        placeholderLabel.isHidden = true
        let c = result.content
        setStatus("Done · \(c.intent.label) · \(c.frames.count) screenshot\(c.frames.count == 1 ? "" : "s"). Copy a prompt below.", isError: false)
        showPanel(index: 0)
        segmented.selectedSegment = 0
    }

    private func rebuildCarousel(_ result: AIBriefBuilder.Result) {
        carouselStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let framesDir = result.bundleDir.appendingPathComponent("frames")
        for f in result.content.frames {
            let url = framesDir.appendingPathComponent(f.filename)
            let image = NSImage(contentsOf: url)

            let thumb = ClickableImageView(fileURL: url)
            thumb.image = image
            thumb.imageScaling = .scaleProportionallyUpOrDown
            thumb.wantsLayer = true
            thumb.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            thumb.layer?.cornerRadius = 6
            thumb.layer?.masksToBounds = true
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.widthAnchor.constraint(equalToConstant: 150).isActive = true
            thumb.heightAnchor.constraint(equalToConstant: 84).isActive = true
            thumb.toolTip = f.note

            let caption = NSTextField(wrappingLabelWithString: "\(AIBrief.timecode(f.t))\(f.note.map { " · \($0)" } ?? "")")
            caption.font = .systemFont(ofSize: 9)
            caption.textColor = .secondaryLabelColor
            caption.maximumNumberOfLines = 2
            caption.lineBreakMode = .byTruncatingTail
            caption.translatesAutoresizingMaskIntoConstraints = false
            caption.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let cell = NSStackView(views: [thumb, caption])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 3
            carouselStack.addArrangedSubview(cell)
        }
        if result.content.frames.isEmpty {
            let none = NSTextField(labelWithString: "No screenshots captured.")
            none.font = .systemFont(ofSize: 11)
            none.textColor = .tertiaryLabelColor
            carouselStack.addArrangedSubview(none)
        }
    }

    private func rebuildFilesList(_ result: AIBriefBuilder.Result) {
        filesListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let dir = result.bundleDir
        var entries: [(String, URL)] = [
            ("BRIEF.md", dir.appendingPathComponent("BRIEF.md")),
            ("PROMPT.md", dir.appendingPathComponent("PROMPT.md")),
            ("brief.json", dir.appendingPathComponent("brief.json")),
            ("transcript.srt", dir.appendingPathComponent("transcript.srt")),
            ("events.json", dir.appendingPathComponent("events.json"))
        ]
        entries.append(("frames/ (\(result.content.frames.count))", dir.appendingPathComponent("frames")))
        for (name, url) in entries where FileManager.default.fileExists(atPath: url.path) {
            let button = NSButton(title: "📄  \(name)", target: self, action: #selector(openFile(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.contentTintColor = .linkColor
            button.alignment = .left
            button.toolTip = url.path
            button.identifier = NSUserInterfaceItemIdentifier(url.path)
            filesListStack.addArrangedSubview(button)
        }
    }

    // MARK: - Panel switching

    @objc private func segmentChanged() { showPanel(index: segmented.selectedSegment) }

    private func showPanel(index: Int) {
        kiroPanel?.isHidden = (index != 0)
        webPanel?.isHidden = (index != 1)
        filesPanel?.isHidden = (index != 2)
        // Keep the placeholder visible (over an empty panel) until a build populates the views.
        if lastBuild != nil { placeholderLabel?.isHidden = true }
        else { placeholderLabel?.isHidden = false; kiroPanel?.isHidden = true; webPanel?.isHidden = true; filesPanel?.isHidden = true }
    }

    // MARK: - Actions

    @objc private func copyKiro() {
        guard let r = lastBuild else { return }
        copyToPasteboard(r.agentPrompt)
        setStatus("Kiro prompt copied. Paste it into Kiro or Claude Code.", isError: false)
    }

    @objc private func copyWeb() {
        guard let r = lastBuild else { return }
        copyToPasteboard(r.webPrompt)
        setStatus("Web prompt copied. Attach the screenshots from the .zip in your browser chat.", isError: false)
    }

    @objc private func downloadZip() {
        guard let r = lastBuild else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = r.zipURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { [weak self] resp in
            guard resp == .OK, let dest = panel.url else { return }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: r.zipURL, to: dest)
                self?.setStatus("Saved \(dest.lastPathComponent).", isError: false)
            } catch {
                self?.setStatus("Couldn't save the zip: \(error.localizedDescription)", isError: true)
            }
        }
    }

    @objc private func revealFolder() {
        guard let r = lastBuild else { return }
        NSWorkspace.shared.activateFileViewerSelecting([r.bundleDir])
    }

    @objc private func openFile(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func changeSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = source.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url
        lastBuild = nil
        reloadSource()
        setControlsEnabled(false)
        collapseHandoff()   // back to stage A (video + Analyze) for the new clip
        showPanel(index: segmented.selectedSegment)
        setStatus("Click Analyze to transcribe, capture frames, and write the brief.", isError: false)
    }

    @objc private func closeWindow() { window?.close() }

    // MARK: - Helpers

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func setBusy(_ busy: Bool) {
        analyzeButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Enables the handoff controls (segments + copy/zip/reveal) once a brief exists.
    private func setControlsEnabled(_ enabled: Bool) {
        segmented.isEnabled = enabled
        copyKiroButton.isEnabled = enabled
        copyWebButton.isEnabled = enabled
        downloadZipButton.isEnabled = enabled
        revealButton.isEnabled = enabled
    }

    private func reloadSource() {
        sourceNameField.stringValue = source.lastPathComponent
        sourceNameField.toolTip = source.path
        if FileManager.default.fileExists(atPath: source.path) {
            sourcePlayer.player = AVPlayer(url: source)
        } else {
            sourcePlayer.player = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        isCancelled = true
        sourcePlayer?.player?.pause()
        window = nil
        onClose?()
        onClose = nil
    }
}

/// An image view that opens its backing file (in Preview/Finder) on click — used for the frame
/// thumbnails in the Files carousel.
@available(macOS 12.3, *)
private final class ClickableImageView: NSImageView {
    private let fileURL: URL
    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { NSWorkspace.shared.open(fileURL) }
}
