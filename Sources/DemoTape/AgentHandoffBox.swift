import AppKit

/// The "or let your coding agent do it" panel, in one place.
///
/// Several windows offer the same escape hatch: the app does the mechanical part, and anything that
/// needs judgement — translating a narration, writing subtitles in another language — is handed to the
/// user's own coding agent as a prompt. Each window had invented its own wording and layout for that,
/// which made a deliberate, app-wide idea look like a one-off in whichever dialog you happened to open.
///
/// One component, one label, one icon, so the pattern reads as the design it is: everything here is
/// agent-drivable, and the app says so the same way every time.
@available(macOS 12.3, *)
final class AgentHandoffBox: NSBox {

    /// The single wording used everywhere. Changing it here changes every window.
    static let copyTitle = "Copy prompt for your agent"

    let button: NSButton
    private let headlineLabel: NSTextField
    private let detailLabel: NSTextField

    /// - Parameters:
    ///   - headline: what the agent will do, in the user's terms.
    ///   - detail: one sentence on how it works and where the result lands.
    ///   - accessory: an optional control that belongs with the headline (e.g. a language picker).
    init(headline: String, detail: String, accessory: NSView? = nil,
         target: AnyObject, action: Selector) {
        button = NSButton(title: Self.copyTitle, target: target, action: action)
        headlineLabel = NSTextField(labelWithString: headline)
        detailLabel = NSTextField(wrappingLabelWithString: detail)
        super.init(frame: .zero)

        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 8
        borderWidth = 1
        borderColor = .separatorColor
        fillColor = .quaternaryLabelColor.withAlphaComponent(0.08)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "sparkles.rectangle.stack",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        headlineLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        button.imagePosition = .imageLeading

        var headlineViews: [NSView] = [icon, headlineLabel]
        if let accessory = accessory { headlineViews.append(accessory) }
        headlineViews.append(NSView())
        let headlineRow = NSStackView(views: headlineViews)
        headlineRow.orientation = .horizontal
        headlineRow.spacing = 8
        headlineRow.alignment = .centerY

        let detailRow = NSStackView(views: [detailLabel, button])
        detailRow.orientation = .horizontal
        detailRow.spacing = 12
        detailRow.alignment = .centerY

        let stack = NSStackView(views: [headlineRow, detailRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            headlineRow.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            detailRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var headline: String {
        get { headlineLabel.stringValue }
        set { headlineLabel.stringValue = newValue }
    }
}
