import AppKit

/// The recorder bar's setup popover — everything you'd change just before pressing Start.
///
/// The floating bar was Start, a timer, mic, webcam and a close button, with no way into any setting:
/// to change a background or turn on the teleprompter you had to go back to the menu-bar icon, where
/// every option in the app lives in one flat list of text. This puts the handful that matter *before a
/// take* where the take is about to happen, and gives the agent path a card of its own rather than a
/// menu row indistinguishable from a checkbox.
@available(macOS 12.3, *)
final class RecorderSetupPopover: NSObject {

    /// Everything the popover needs the app to do. Callbacks rather than direct calls, so the popover
    /// stays a view and the behaviour stays in one place (`AppDelegate`).
    struct Actions {
        var setFullScreen: (Bool) -> Void
        var openComposer: () -> Void
        var openBackground: () -> Void
        var toggleBranding: () -> Void
        var toggleTeleprompter: () -> Void
        var toggleAutoZoom: () -> Void
        var toggleMirror: () -> Void
        var openAudio: () -> Void
        var openWebcam: () -> Void
        var openAISettings: () -> Void
    }

    private var popover: NSPopover?
    private var actions: Actions
    private var modeControl: NSSegmentedControl!
    private var backgroundValue: NSTextField!
    private var brandingSwitch: NSSwitch!
    private var teleprompterSwitch: NSSwitch!
    private var autoZoomSwitch: NSSwitch!
    private var mirrorSwitch: NSSwitch!

    init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    // MARK: - Presentation

    func show(relativeTo view: NSView) {
        if popover == nil { build() }
        refresh()
        popover?.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func close() { popover?.close() }
    var isShown: Bool { popover?.isShown ?? false }

    /// Re-reads Settings so the popover always shows the truth, including changes made from the menu.
    func refresh() {
        guard modeControl != nil else { return }
        modeControl.selectedSegment = Settings.useRegion ? 1 : 0
        backgroundValue.stringValue = Settings.framedBackground ? Self.backgroundLabel() : "Off"
        brandingSwitch.state = Settings.brandingEnabled ? .on : .off
        teleprompterSwitch.state = Settings.teleprompterEnabled ? .on : .off
        autoZoomSwitch.state = Settings.autoZoomEnabled ? .on : .off
        mirrorSwitch.state = Settings.mirrorCamera ? .on : .off
    }

    /// A readable name for the chosen background file ("Gradient Wave 01"), not its filename.
    static func backgroundLabel() -> String {
        let stem = (Settings.backgroundFile as NSString).deletingPathExtension
        let words = stem.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "wallpaper", with: "")
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return words.map { $0.count <= 2 ? $0 : $0.capitalized }.joined(separator: " ")
    }

    // MARK: - Build

    private func build() {
        let width: CGFloat = 300
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        modeControl = NSSegmentedControl(labels: ["Full Screen", "Select Area"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged))
        modeControl.segmentDistribution = .fillEqually
        content.addArrangedSubview(modeControl)

        // The agent path, as a card: two ways to get a video, and this one isn't a setting.
        content.addArrangedSubview(agentCard())

        content.addArrangedSubview(header("Recording setup"))
        backgroundValue = NSTextField(labelWithString: "")
        backgroundValue.font = .systemFont(ofSize: 12)
        backgroundValue.textColor = .secondaryLabelColor
        content.addArrangedSubview(disclosureRow(icon: "photo", title: "Background",
                                                 value: backgroundValue,
                                                 action: #selector(tapBackground)))
        brandingSwitch = NSSwitch()
        brandingSwitch.target = self; brandingSwitch.action = #selector(tapBranding)
        content.addArrangedSubview(switchRow(icon: "signature", title: "Branding", control: brandingSwitch))
        teleprompterSwitch = NSSwitch()
        teleprompterSwitch.target = self; teleprompterSwitch.action = #selector(tapTeleprompter)
        content.addArrangedSubview(switchRow(icon: "text.alignleft", title: "Teleprompter",
                                             control: teleprompterSwitch))
        autoZoomSwitch = NSSwitch()
        autoZoomSwitch.target = self; autoZoomSwitch.action = #selector(tapAutoZoom)
        content.addArrangedSubview(switchRow(icon: "viewfinder", title: "Auto-Zoom", control: autoZoomSwitch))
        mirrorSwitch = NSSwitch()
        mirrorSwitch.target = self; mirrorSwitch.action = #selector(tapMirror)
        content.addArrangedSubview(switchRow(icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                             title: "Mirror camera", control: mirrorSwitch))

        content.addArrangedSubview(spacer(4))
        content.addArrangedSubview(disclosureRow(icon: "mic", title: "Microphone & audio settings…",
                                                 value: nil, action: #selector(tapAudio)))
        content.addArrangedSubview(disclosureRow(icon: "video", title: "Webcam settings…",
                                                 value: nil, action: #selector(tapWebcam)))
        content.addArrangedSubview(spacer(4))
        content.addArrangedSubview(disclosureRow(icon: "gearshape", title: "AI Settings…",
                                                 value: nil, action: #selector(tapAISettings)))

        for row in content.arrangedSubviews {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12).isActive = true
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12).isActive = true
        }

        let host = NSViewController()
        host.view = content
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: width).isActive = true

        let pop = NSPopover()
        pop.contentViewController = host
        pop.behavior = .transient          // click away to dismiss, like every other macOS popover
        pop.animates = true
        popover = pop
    }

    private func header(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func icon(_ name: String) -> NSImageView {
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        iv.contentTintColor = .controlAccentColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return iv
    }

    private func agentCard() -> NSView {
        let card = HoverCard()
        card.target = self
        card.action = #selector(tapComposer)

        let art = NSImageView()
        art.image = NSImage(systemSymbolName: "sparkles.rectangle.stack",
                            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        art.contentTintColor = .controlAccentColor
        art.translatesAutoresizingMaskIntoConstraints = false
        art.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let title = NSTextField(labelWithString: "Let your coding agent record this")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let sub = NSTextField(labelWithString: "Scripted, narrated, verified — hands-off")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor

        let row = NSStackView(views: [art, text, NSView(), chevron])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10)
        ])
        return card
    }

    /// A row that opens something. Whole row is the hit target, as in a settings list.
    private func disclosureRow(icon name: String, title: String,
                               value: NSTextField?, action: Selector) -> NSView {
        let card = HoverCard()
        card.target = self
        card.action = action

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor

        var views: [NSView] = [icon(name), label, NSView()]
        if let value = value { views.append(value) }
        views.append(chevron)
        return wrap(views, in: card)
    }

    /// A row that toggles something in place — no navigation, so no chevron and no hit-target on the row.
    private func switchRow(icon name: String, title: String, control: NSSwitch) -> NSView {
        let card = HoverCard()
        card.isEnabled = false            // the switch is the control; the row isn't clickable
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        control.controlSize = .small
        return wrap([icon(name), label, NSView(), control], in: card)
    }

    private func wrap(_ views: [NSView], in card: HoverCard) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10)
        ])
        return card
    }

    // MARK: - Actions
    //
    // Toggles keep the popover open (you often flip two of them); anything that opens a window closes
    // it first, so the popover isn't left floating over the window it just opened.

    @objc private func modeChanged() {
        actions.setFullScreen(modeControl.selectedSegment == 0)
        refresh()
    }
    @objc private func tapComposer() { close(); actions.openComposer() }
    @objc private func tapBackground() { close(); actions.openBackground() }
    @objc private func tapBranding() { actions.toggleBranding(); refresh() }
    @objc private func tapTeleprompter() { actions.toggleTeleprompter(); refresh() }
    @objc private func tapAutoZoom() { actions.toggleAutoZoom(); refresh() }
    @objc private func tapMirror() { actions.toggleMirror(); refresh() }
    @objc private func tapAudio() { close(); actions.openAudio() }
    @objc private func tapWebcam() { close(); actions.openWebcam() }
    @objc private func tapAISettings() { close(); actions.openAISettings() }
}

/// A rounded row that lights up under the pointer, so a list of settings reads as a list of controls.
@available(macOS 12.3, *)
final class HoverCard: NSControl {

    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.10).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHover(isEnabled) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let action = action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    private func setHover(_ on: Bool) {
        layer?.backgroundColor = (on ? NSColor.quaternaryLabelColor.withAlphaComponent(0.20)
                                     : NSColor.quaternaryLabelColor.withAlphaComponent(0.10)).cgColor
    }
}
