import AppKit
import AVKit
import UniformTypeIdentifiers

/// Base for a **focused action window**: one job, one screen.
///
/// - Top-left: the file we're working on, with a **Change…** button to point at another.
/// - Below: two players (Source left, Result right).
/// - Center: the action's controls with a single prominent **Generate preview** button. Because
///   generating writes the output straight to disk, there's no separate save step — the finished
///   file simply appears as a link with a **Reveal in Finder** button beneath the button.
/// - Bottom-left: **Cancel** (closes the window).
///
/// Subclasses provide the title, the centered controls, and the render itself.
@available(macOS 12.3, *)
class ActionPreviewController: NSObject, NSWindowDelegate {

    private(set) var source: URL
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    private var sourceNameField: NSTextField!
    private var sourcePlayer: AVPlayerView!
    private var resultPlayer: AVPlayerView!
    private var resultBadge: NSTextField!
    private var generateButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var messageLabel: NSTextField!
    private var resultRow: NSStackView!
    private var resultLink: NSButton!

    private var lastResult: URL?

    init(source: URL) {
        self.source = source
        super.init()
    }

    // MARK: - Subclass hooks

    /// Window title. Keep it a plain phrase — no parentheses.
    var actionTitle: String { "Action" }

    /// The centered controls for this action (e.g. a speed selector).
    func makeControls() -> NSView { NSView() }

    /// Render the current settings against `source`. Return the output URL, or `nil` when there's
    /// genuinely nothing to produce (base shows `nothingMessage`). Throw to report a failure.
    /// Called off the main thread; report progress via `progress` (0…1).
    func render(progress: @escaping (Double) -> Void) throws -> URL? { nil }

    /// Message shown when `render` returns nil.
    var nothingMessage: String { "Nothing to generate." }

    /// Called once after the window is on screen — a place to kick off work (e.g. transcribe).
    func windowDidAppear() {}

    /// Called after the user picks a different source with Change… (subclasses can re-prefill).
    func sourceDidChange() {}

    /// Asked on the main thread just before a generate starts. Return false to abort (e.g. the
    /// user declined a paid-operation confirmation). Default allows it.
    func confirmBeforeGenerate() -> Bool { true }

    /// True once the window is closing — long-running `render` implementations should poll this
    /// and bail out early so closing the window cancels the work.
    private(set) var isCancelled = false

    /// When true, the controls view stretches to the full content width (e.g. a transcript tab
    /// under the video) instead of hugging its intrinsic width centered.
    var controlsFillWidth: Bool { false }

    // MARK: - Presentation

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = actionTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 780, height: 680)
        window.contentView = buildContent()
        self.window = window

        reloadSource()

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        windowDidAppear()
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let root = NSView()
        let inset: CGFloat = 24

        // Header: working file + Change…
        sourceNameField = NSTextField(labelWithString: "")
        sourceNameField.font = .systemFont(ofSize: 13, weight: .medium)
        sourceNameField.lineBreakMode = .byTruncatingMiddle
        sourceNameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let changeButton = NSButton(title: "Change…", target: self, action: #selector(changeSource))
        changeButton.bezelStyle = .rounded

        // Players.
        sourcePlayer = makePlayerView()
        resultPlayer = makePlayerView()
        let sourceCol = playerColumn(title: "Source", player: sourcePlayer, badge: nil)
        resultBadge = NSTextField(labelWithString: "not generated yet")
        resultBadge.font = .systemFont(ofSize: 10)
        resultBadge.textColor = .tertiaryLabelColor
        let resultCol = playerColumn(title: "Result", player: resultPlayer, badge: resultBadge)
        let players = NSStackView(views: [sourceCol, resultCol])
        players.distribution = .fillEqually
        players.spacing = 16

        // Center: controls + generate + progress + result link.
        let controls = makeControls()

        generateButton = NSButton(title: "Generate preview", target: self, action: #selector(generateTapped))
        generateButton.bezelStyle = .rounded
        generateButton.controlSize = .large
        generateButton.keyEquivalent = "\r"

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center

        resultLink = NSButton(title: "", target: self, action: #selector(revealResult))
        resultLink.isBordered = false
        resultLink.contentTintColor = .linkColor
        let revealButton = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealResult))
        revealButton.bezelStyle = .rounded
        resultRow = NSStackView(views: [resultLink, revealButton])
        resultRow.orientation = .horizontal
        resultRow.spacing = 8
        resultRow.isHidden = true

        // Controls area (subclass-supplied). Full-width when requested (e.g. transcript tab).
        let controlsHost = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsHost.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: controlsHost.topAnchor),
            controls.bottomAnchor.constraint(equalTo: controlsHost.bottomAnchor),
            controls.centerXAnchor.constraint(equalTo: controlsHost.centerXAnchor)
        ])
        if controlsFillWidth {
            controls.leadingAnchor.constraint(equalTo: controlsHost.leadingAnchor).isActive = true
            controls.trailingAnchor.constraint(equalTo: controlsHost.trailingAnchor).isActive = true
        }

        // Action cluster (centered): the prominent Generate button, progress, and result link.
        let cluster = NSStackView(views: [generateButton, spinner, messageLabel, resultRow])
        cluster.orientation = .vertical
        cluster.alignment = .centerX
        cluster.spacing = 12

        // Footer: Cancel bottom-left.
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded

        [sourceNameField, changeButton, players, controlsHost, cluster, cancelButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            sourceNameField.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            sourceNameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            changeButton.centerYAnchor.constraint(equalTo: sourceNameField.centerYAnchor),
            changeButton.leadingAnchor.constraint(equalTo: sourceNameField.trailingAnchor, constant: 8),
            changeButton.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -inset),

            players.topAnchor.constraint(equalTo: sourceNameField.bottomAnchor, constant: 12),
            players.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            players.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            players.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.42),

            controlsHost.topAnchor.constraint(equalTo: players.bottomAnchor, constant: 18),
            controlsHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            controlsHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

            // The Generate cluster sits directly below the controls (not jammed at the bottom).
            cluster.topAnchor.constraint(equalTo: controlsHost.bottomAnchor, constant: 24),
            cluster.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            cluster.bottomAnchor.constraint(lessThanOrEqualTo: cancelButton.topAnchor, constant: -14),

            cancelButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset)
        ])
        return root
    }

    private func makePlayerView() -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.cornerRadius = 6
        return v
    }

    private func playerColumn(title: String, player: AVPlayerView, badge: NSTextField?) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let header = NSStackView(views: [label])
        header.orientation = .horizontal
        if let badge = badge { header.addArrangedSubview(badge) }
        let col = NSStackView(views: [header, player])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        player.translatesAutoresizingMaskIntoConstraints = false
        player.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    // MARK: - Actions

    @objc private func changeSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = source.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url
        lastResult = nil
        resultRow.isHidden = true
        resultPlayer.player = nil
        resultBadge.stringValue = "not generated yet"
        messageLabel.stringValue = ""
        reloadSource()
        sourceDidChange()
    }

    @objc private func generateTapped() {
        guard confirmBeforeGenerate() else { return }
        isCancelled = false
        setBusy(true)
        resultRow.isHidden = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let out = try self.render { p in
                    DispatchQueue.main.async { self.setStatus("Rendering… \(Int(p * 100))%", isError: false) }
                }
                DispatchQueue.main.async {
                    self.setBusy(false)
                    if let out = out {
                        self.lastResult = out
                        self.load(out, into: self.resultPlayer)
                        self.resultPlayer.player?.play()
                        self.resultBadge.stringValue = out.lastPathComponent
                        self.resultLink.title = out.lastPathComponent
                        self.resultRow.isHidden = false
                        self.setStatus("", isError: false)
                    } else {
                        self.setStatus(self.nothingMessage, isError: false)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @objc private func revealResult() {
        if let url = lastResult { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func cancelTapped() { window?.close() }

    // MARK: - Helpers (available to subclasses)

    /// Show a message under the Generate button (progress, hints, or errors).
    func setStatus(_ text: String, isError: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    /// Toggle the working state: disables Generate and spins while true.
    func setBusy(_ busy: Bool) {
        generateButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func reloadSource() {
        load(source, into: sourcePlayer)
        sourceNameField.stringValue = source.lastPathComponent
        sourceNameField.toolTip = source.path
    }

    private func load(_ url: URL?, into view: AVPlayerView) {
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else {
            view.player = nil
            return
        }
        view.player = AVPlayer(url: url)
    }

    func windowWillClose(_ notification: Notification) {
        isCancelled = true          // let any long-running render bail out
        sourcePlayer?.player?.pause()
        resultPlayer?.player?.pause()
        window = nil
        onClose?()
        onClose = nil
    }
}
