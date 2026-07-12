import AppKit

/// Temporary bottom-panel content used by the Studio shell until each tool's real panel lands
/// in the following commits.
@available(macOS 12.3, *)
final class StudioPlaceholderPanel: NSView, StudioToolPanel {
    private let label = NSTextField(labelWithString: "")

    init(tool: StudioTool) {
        super.init(frame: .zero)
        label.stringValue = "\(tool.title) controls appear here."
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func activate(host: StudioHost) {}
}
