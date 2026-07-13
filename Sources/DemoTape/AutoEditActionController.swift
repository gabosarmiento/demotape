import AppKit
import AVFoundation

/// Focused "Auto-Edit" action — one place to re-edit the latest recording. The first choice is
/// the **smart local director** (cuts between screen and webcam from your clicks/pauses), then a
/// placeholder for the upcoming **AI** edit, then the paced **templates**. All render through the
/// TemplateComposer into a final file. Local, no network.
@available(macOS 12.3, *)
final class AutoEditActionController: ActionPreviewController {

    private enum Mode: Equatable { case director, ai, template(Int) }

    private var stylePopup: NSPopUpButton!
    private var descriptionLabel: NSTextField!
    private var modes: [Mode] = []

    override var actionTitle: String { "Auto-Edit" }
    override var nothingMessage: String { "Nothing to generate." }

    override func makeControls() -> NSView {
        stylePopup = NSPopUpButton()
        modes = []

        stylePopup.addItem(withTitle: "Smart · reads your clicks & pauses (Local)")
        modes.append(.director)
        stylePopup.addItem(withTitle: "Smart · AI — coming soon")
        modes.append(.ai)
        for (i, t) in VideoTemplate.catalog.enumerated() {
            stylePopup.addItem(withTitle: t.name)
            modes.append(.template(i))
        }
        // The AI option is a roadmap placeholder — visible but not selectable yet.
        stylePopup.menu?.autoenablesItems = false
        stylePopup.menu?.items[1].isEnabled = false
        stylePopup.selectItem(at: 0)
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)

        let label = NSTextField(labelWithString: "Style")
        label.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [label, stylePopup])
        row.orientation = .horizontal
        row.spacing = 10

        descriptionLabel = NSTextField(wrappingLabelWithString: "")
        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.widthAnchor.constraint(equalToConstant: 480).isActive = true

        let stack = NSStackView(views: [row, descriptionLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        return stack
    }

    override func windowDidAppear() { updateDescription() }

    @objc private func styleChanged() { updateDescription() }

    private func updateDescription() {
        switch mode(at: stylePopup.indexOfSelectedItem) {
        case .director:
            descriptionLabel.stringValue =
                "Reads your clicks, typing, and pauses and cuts between your screen and webcam "
                + "like a live director — holding on the screen while you work, cutting to you on "
                + "the pauses. Never cuts mid-click."
        case .ai:
            descriptionLabel.stringValue =
                "Coming soon: understands your narration to emphasize exactly what you're explaining."
        case .template(let i):
            descriptionLabel.stringValue = VideoTemplate.catalog[i].persona
        }
    }

    private func mode(at index: Int) -> Mode {
        guard index >= 0, index < modes.count else { return .director }
        return modes[index]
    }

    override func render(progress: @escaping (Double) -> Void) throws -> URL? {
        let paths = SourcePaths(source: source)
        let cam = paths.camera
        let branding: URL? = {
            guard Settings.brandingEnabled, !Settings.brandingImagePath.isEmpty,
                  FileManager.default.fileExists(atPath: Settings.brandingImagePath) else { return nil }
            return URL(fileURLWithPath: Settings.brandingImagePath)
        }()

        switch mode(at: stylePopup.indexOfSelectedItem) {
        case .ai:
            DispatchQueue.main.async { self.setStatus("The AI edit is coming soon — try Smart (Local).", isError: false) }
            return nil

        case .director:
            guard let eventsURL = paths.events else {
                DispatchQueue.main.async { self.setStatus("No event timeline for this file — record fresh to use the director.", isError: true) }
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(RecordingMetadata.self, from: Data(contentsOf: eventsURL))
            let timeline = AutoDirector.plan(metadata: metadata, hasWebcam: cam != nil)
            let template = VideoTemplate(id: "director", name: "AI Director", persona: "", tags: [],
                                         plan: { _ in timeline })
            let out = paths.output(suffix: "director")
            try TemplateComposer().compose(master: source, cam: cam, branding: branding,
                                           template: template, to: out, progress: progress)
            return out

        case .template(let i):
            let t = VideoTemplate.catalog[i]
            let out = paths.templateOutput(id: t.id)
            try TemplateComposer().compose(master: source, cam: cam, branding: branding,
                                           template: t, to: out, progress: progress)
            return out
        }
    }
}
