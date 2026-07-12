import AppKit

/// Edit tool: local, no-network editing of the current source — Auto-Cut & Speed Up (Tightener)
/// and the one-click auto-edit Templates. Generates a candidate, previews it on the right, and
/// bakes it into a new source revision on Approve.
@available(macOS 12.3, *)
final class StudioEditPanel: NSView, StudioToolPanel {

    private weak var host: StudioHost?
    private var pendingResult: URL?

    private let speeds: [Double] = [1.0, 1.1, 1.25, 1.5]
    private var silenceBox: NSButton!
    private var speedPopup: NSPopUpButton!
    private var cutButton: NSButton!
    private var templatePopup: NSPopUpButton!
    private var templateNote: NSTextField!
    private var templateButton: NSButton!
    private var approveButton: NSButton!
    private var spinner: NSProgressIndicator!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func activate(host: StudioHost) {
        self.host = host
        pendingResult = nil
        approveButton.isEnabled = false
        syncTemplateNote()
    }

    // MARK: - Layout

    private func build() {
        // Auto-Cut group.
        let cutTitle = sectionTitle("Auto-Cut & Speed Up")
        silenceBox = NSButton(checkboxWithTitle: "Remove silent gaps", target: nil, action: nil)
        silenceBox.state = .on
        let speedLabel = NSTextField(labelWithString: "Speed")
        speedLabel.font = .systemFont(ofSize: 12)
        speedPopup = NSPopUpButton()
        speedPopup.addItems(withTitles: speeds.map { $0 == 1.0 ? "1.0× (none)" : "\($0)×" })
        speedPopup.selectItem(at: 0)
        cutButton = NSButton(title: "Generate cut", target: self, action: #selector(runCut))
        cutButton.bezelStyle = .rounded
        let cutRow = NSStackView(views: [silenceBox, speedLabel, speedPopup, cutButton])
        cutRow.orientation = .horizontal
        cutRow.spacing = 10
        let cutGroup = NSStackView(views: [cutTitle, cutRow])
        cutGroup.orientation = .vertical
        cutGroup.alignment = .leading
        cutGroup.spacing = 6

        // Templates group.
        let tplTitle = sectionTitle("Templates")
        templatePopup = NSPopUpButton()
        templatePopup.addItems(withTitles: VideoTemplate.catalog.map { $0.name })
        templatePopup.target = self
        templatePopup.action = #selector(templateChanged)
        templateButton = NSButton(title: "Apply template", target: self, action: #selector(runTemplate))
        templateButton.bezelStyle = .rounded
        let tplRow = NSStackView(views: [templatePopup, templateButton])
        tplRow.orientation = .horizontal
        tplRow.spacing = 10
        templateNote = NSTextField(wrappingLabelWithString: "")
        templateNote.font = .systemFont(ofSize: 11)
        templateNote.textColor = .secondaryLabelColor
        let tplGroup = NSStackView(views: [tplTitle, tplRow, templateNote])
        tplGroup.orientation = .vertical
        tplGroup.alignment = .leading
        tplGroup.spacing = 6

        // Footer: spinner + approve.
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        approveButton = NSButton(title: "Approve result → make it the source",
                                 target: self, action: #selector(approve))
        approveButton.bezelStyle = .rounded
        approveButton.isEnabled = false
        let footer = NSStackView(views: [spinner, NSView(), approveButton])
        footer.orientation = .horizontal

        let column = NSStackView(views: [cutGroup, divider(), tplGroup, NSView(), footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
    }

    private func sectionTitle(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        return t
    }
    private func divider() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 1).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return b
    }

    // MARK: - Actions

    @objc private func templateChanged() { syncTemplateNote() }
    private func syncTemplateNote() {
        let t = VideoTemplate.catalog[max(0, templatePopup.indexOfSelectedItem)]
        templateNote.stringValue = t.persona
    }

    @objc private func runCut() {
        guard let host = host else { return }
        var opts = Tightener.Options()
        opts.removeSilence = (silenceBox.state == .on)
        opts.speed = speeds[speedPopup.indexOfSelectedItem]
        guard opts.removeSilence || opts.speed != 1.0 else {
            host.setStatus("Pick silence removal or a speed above 1.0×.", isError: true)
            return
        }
        let source = host.currentSource
        let out = host.project.tight
        setBusy(true)
        host.setStatus("Analyzing & rendering cut…", isError: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                _ = try Tightener().tighten(video: source, options: opts, to: out)
                DispatchQueue.main.async { self?.finished(out) }
            } catch {
                DispatchQueue.main.async { self?.failed(error) }
            }
        }
    }

    @objc private func runTemplate() {
        guard let host = host else { return }
        let template = VideoTemplate.catalog[max(0, templatePopup.indexOfSelectedItem)]
        let source = host.currentSource
        let out = host.project.directory
            .appendingPathComponent("\(host.project.stem.replacingOccurrences(of: ".styled", with: ""))-\(template.id).mp4")
        let cam = FileManager.default.fileExists(atPath: host.project.camera.path) ? host.project.camera : nil
        let branding: URL? = {
            guard Settings.brandingEnabled, !Settings.brandingImagePath.isEmpty,
                  FileManager.default.fileExists(atPath: Settings.brandingImagePath) else { return nil }
            return URL(fileURLWithPath: Settings.brandingImagePath)
        }()
        setBusy(true)
        host.setStatus("Rendering “\(template.name)”… 0%", isError: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try TemplateComposer().compose(master: source, cam: cam, branding: branding,
                                               template: template, to: out) { p in
                    DispatchQueue.main.async {
                        self?.host?.setStatus("Rendering “\(template.name)”… \(Int(p * 100))%", isError: false)
                    }
                }
                DispatchQueue.main.async { self?.finished(out) }
            } catch {
                DispatchQueue.main.async { self?.failed(error) }
            }
        }
    }

    private func finished(_ out: URL) {
        setBusy(false)
        pendingResult = out
        approveButton.isEnabled = true
        host?.preview(out)
        host?.setStatus("Preview ready on the right. Approve to make it the source.", isError: false)
    }

    private func failed(_ error: Error) {
        setBusy(false)
        host?.setStatus("Edit failed: \(error.localizedDescription)", isError: true)
    }

    @objc private func approve() {
        guard let out = pendingResult else { return }
        host?.approve(out)
        pendingResult = nil
        approveButton.isEnabled = false
    }

    private func setBusy(_ busy: Bool) {
        cutButton.isEnabled = !busy
        templateButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
