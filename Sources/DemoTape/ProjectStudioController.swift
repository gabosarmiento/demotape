import AppKit
import AVKit

/// The **Project Studio**: one window to take a recording all the way to a finished demo.
///
/// Layout
/// - Left rail: the five tools (Edit / Caption / Audio / Avatar / Output).
/// - Top: two players side by side — **Source** (the current approved revision) and **Result**
///   (a candidate preview from the active tool).
/// - Bottom: the active tool's parameter panel, then a status line.
///
/// Pipeline model (non-destructive): a tool reads `currentSource`, previews a candidate on the
/// right, and on **Approve** that candidate becomes the new source (pushed onto a revision
/// stack). **Revert** walks the stack back so the user can undo without losing files.
@available(macOS 12.3, *)
final class ProjectStudioController: NSObject, NSWindowDelegate, StudioHost {

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    // Data
    private(set) var project: Project
    private var revisions: [URL]                 // source revision stack; last == current
    var currentSource: URL { revisions.last ?? project.bestSource }

    // UI
    private var projectPopup: NSPopUpButton!
    private var revertButton: NSButton!
    private var railButtons: [NSButton] = []
    private var sourcePlayer: AVPlayerView!
    private var resultPlayer: AVPlayerView!
    private var resultBadge: NSTextField!
    private var panelContainer: NSView!
    private var statusLabel: NSTextField!
    private var currentTool: StudioTool = .edit
    private var activePanel: StudioToolPanel?

    private var allProjects: [Project] = []

    init(project: Project) {
        self.project = project
        self.revisions = [project.bestSource]
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Project Studio"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 860, height: 600)
        window.contentView = buildContent()
        self.window = window

        reloadProjectsPopup()
        selectTool(.edit)
        reloadSource()

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

@available(macOS 12.3, *)
extension ProjectStudioController {

    // MARK: - Layout

    private func buildContent() -> NSView {
        let root = NSView()

        // Header: project picker + revert.
        let projectLabel = NSTextField(labelWithString: "Project")
        projectLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        projectLabel.textColor = .secondaryLabelColor

        projectPopup = NSPopUpButton()
        projectPopup.target = self
        projectPopup.action = #selector(projectChanged)

        revertButton = NSButton(title: "Revert", target: self, action: #selector(revertTapped))
        revertButton.bezelStyle = .rounded
        revertButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Revert")
        revertButton.imagePosition = .imageLeading
        revertButton.isEnabled = false

        let revealButton = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealTapped))
        revealButton.bezelStyle = .rounded

        // Left rail of tools.
        let rail = NSStackView()
        rail.orientation = .vertical
        rail.alignment = .centerX
        rail.spacing = 6
        rail.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        for tool in StudioTool.allCases {
            let b = railButton(for: tool)
            railButtons.append(b)
            rail.addArrangedSubview(b)
        }
        let railBox = NSView()
        railBox.wantsLayer = true
        railBox.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        railBox.addSubview(rail)
        rail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: railBox.topAnchor),
            rail.leadingAnchor.constraint(equalTo: railBox.leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: railBox.trailingAnchor)
        ])

        // Players.
        sourcePlayer = makePlayerView()
        resultPlayer = makePlayerView()
        let sourceCol = playerColumn(title: "Source", player: sourcePlayer, badge: nil)
        resultBadge = NSTextField(labelWithString: "not generated yet")
        resultBadge.font = .systemFont(ofSize: 10)
        resultBadge.textColor = .tertiaryLabelColor
        let resultCol = playerColumn(title: "Result", player: resultPlayer, badge: resultBadge)

        let playersRow = NSStackView(views: [sourceCol, resultCol])
        playersRow.distribution = .fillEqually
        playersRow.spacing = 12

        // Bottom parameter panel container + status.
        panelContainer = NSView()
        panelContainer.wantsLayer = true

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        // Assemble with Auto Layout.
        [projectLabel, projectPopup, revertButton, revealButton, railBox,
         playersRow, panelContainer, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            projectLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            projectLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            projectPopup.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),
            projectPopup.leadingAnchor.constraint(equalTo: projectLabel.trailingAnchor, constant: 8),
            projectPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),

            revealButton.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),
            revealButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            revertButton.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),
            revertButton.trailingAnchor.constraint(equalTo: revealButton.leadingAnchor, constant: -8),

            railBox.topAnchor.constraint(equalTo: projectPopup.bottomAnchor, constant: 12),
            railBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            railBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            railBox.widthAnchor.constraint(equalToConstant: 84),

            playersRow.topAnchor.constraint(equalTo: railBox.topAnchor, constant: 8),
            playersRow.leadingAnchor.constraint(equalTo: railBox.trailingAnchor, constant: 12),
            playersRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            playersRow.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.5),

            panelContainer.topAnchor.constraint(equalTo: playersRow.bottomAnchor, constant: 12),
            panelContainer.leadingAnchor.constraint(equalTo: railBox.trailingAnchor, constant: 12),
            panelContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            panelContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: railBox.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        return root
    }

    private func railButton(for tool: StudioTool) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.imagePosition = .imageAbove
        b.title = tool.title
        b.font = .systemFont(ofSize: 10)
        b.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)
        b.imageScaling = .scaleProportionallyUpOrDown
        b.target = self
        b.action = #selector(toolTapped(_:))
        b.tag = tool.rawValue
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 72),
            b.heightAnchor.constraint(equalToConstant: 56)
        ])
        return b
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
        col.spacing = 4
        player.translatesAutoresizingMaskIntoConstraints = false
        player.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }
}

@available(macOS 12.3, *)
extension ProjectStudioController {

    // MARK: - Tool selection

    @objc private func toolTapped(_ sender: NSButton) {
        guard let tool = StudioTool(rawValue: sender.tag) else { return }
        selectTool(tool)
    }

    private func selectTool(_ tool: StudioTool) {
        currentTool = tool
        for b in railButtons {
            let selected = b.tag == tool.rawValue
            b.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        }
        // Swap the bottom panel.
        activePanel?.removeFromSuperview()
        let panel = makePanel(for: tool)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: panelContainer.topAnchor),
            panel.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor)
        ])
        activePanel = panel
        panel.activate(host: self)
    }

    /// Factory for each tool's parameter panel. The Studio shell uses placeholders; later commits
    /// return the real panels here.
    private func makePanel(for tool: StudioTool) -> StudioToolPanel {
        switch tool {
        case .edit: return StudioEditPanel()
        default:    return StudioPlaceholderPanel(tool: tool)
        }
    }

    // MARK: - Project switching

    private func reloadProjectsPopup() {
        allProjects = ProjectStore.list()
        // Ensure the current project is present even if the folder scan missed it.
        if !allProjects.contains(project) { allProjects.insert(project, at: 0) }
        projectPopup.removeAllItems()
        for p in allProjects { projectPopup.addItem(withTitle: p.displayName) }
        if let idx = allProjects.firstIndex(of: project) { projectPopup.selectItem(at: idx) }
    }

    @objc private func projectChanged() {
        let idx = projectPopup.indexOfSelectedItem
        guard idx >= 0, idx < allProjects.count else { return }
        let chosen = allProjects[idx]
        guard chosen != project else { return }
        project = chosen
        revisions = [chosen.bestSource]
        reloadSource()
        selectTool(currentTool)   // re-activate the panel against the new source
        setStatus("Switched to “\(chosen.displayName)”.", isError: false)
    }

    @objc private func revealTapped() {
        NSWorkspace.shared.activateFileViewerSelecting([currentSource])
    }

    @objc private func revertTapped() {
        guard revisions.count > 1 else { return }
        let removed = revisions.removeLast()
        reloadSource()
        // Clear the result player — the previewed candidate no longer applies.
        resultPlayer.player = nil
        resultBadge.stringValue = "not generated yet"
        selectTool(currentTool)
        setStatus("Reverted to the previous version (\(removed.lastPathComponent) kept on disk).", isError: false)
    }

    // MARK: - StudioHost

    func preview(_ url: URL) {
        load(url, into: resultPlayer)
        resultBadge.stringValue = url.lastPathComponent
    }

    func approve(_ url: URL) {
        revisions.append(url)
        reloadSource()
        resultPlayer.player = nil
        resultBadge.stringValue = "approved → now the source"
        revertButton.isEnabled = revisions.count > 1
        refreshProject()
        selectTool(currentTool)
        setStatus("Approved. “\(url.lastPathComponent)” is now the source.", isError: false)
    }

    func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    func refreshProject() {
        project = ProjectStore.project(for: project.recording) ?? project
    }

    // MARK: - Players

    private func reloadSource() {
        load(currentSource, into: sourcePlayer)
        revertButton.isEnabled = revisions.count > 1
    }

    private func load(_ url: URL?, into view: AVPlayerView) {
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else {
            view.player = nil
            return
        }
        view.player = AVPlayer(url: url)
    }

    // MARK: - Window lifecycle

    func windowWillClose(_ notification: Notification) {
        sourcePlayer?.player?.pause()
        resultPlayer?.player?.pause()
        window = nil
        onClose?()
    }
}
