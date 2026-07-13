import AppKit

/// Focused "Apply Template" action. Pick a paced look; Generate preview re-edits the source into
/// a final `…-<template>.mp4`. Local, no network, no cost.
@available(macOS 12.3, *)
final class TemplateActionController: ActionPreviewController {

    private var templatePopup: NSPopUpButton!
    private var personaLabel: NSTextField!

    override var actionTitle: String { "Apply Template" }
    override var nothingMessage: String { "Pick a template first." }

    override func makeControls() -> NSView {
        templatePopup = NSPopUpButton()
        templatePopup.addItems(withTitles: VideoTemplate.catalog.map { $0.name })
        templatePopup.target = self
        templatePopup.action = #selector(templateChanged)

        let label = NSTextField(labelWithString: "Template")
        label.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [label, templatePopup])
        row.orientation = .horizontal
        row.spacing = 10

        personaLabel = NSTextField(wrappingLabelWithString: "")
        personaLabel.font = .systemFont(ofSize: 11)
        personaLabel.textColor = .secondaryLabelColor
        personaLabel.alignment = .center
        personaLabel.translatesAutoresizingMaskIntoConstraints = false
        personaLabel.widthAnchor.constraint(equalToConstant: 460).isActive = true

        let stack = NSStackView(views: [row, personaLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        return stack
    }

    override func windowDidAppear() {
        updatePersona()
        setStatus("Pick a look, then Generate preview.", isError: false)
    }

    @objc private func templateChanged() { updatePersona() }
    private func updatePersona() {
        let t = VideoTemplate.catalog[max(0, templatePopup.indexOfSelectedItem)]
        personaLabel.stringValue = t.persona
    }

    override func render(progress: @escaping (Double) -> Void) throws -> URL? {
        let template = VideoTemplate.catalog[max(0, templatePopup.indexOfSelectedItem)]
        let paths = SourcePaths(source: source)
        let out = paths.templateOutput(id: template.id)
        let branding: URL? = {
            guard Settings.brandingEnabled, !Settings.brandingImagePath.isEmpty,
                  FileManager.default.fileExists(atPath: Settings.brandingImagePath) else { return nil }
            return URL(fileURLWithPath: Settings.brandingImagePath)
        }()
        try TemplateComposer().compose(master: source, cam: paths.camera, branding: branding,
                                       template: template, to: out, progress: progress)
        return out
    }
}
