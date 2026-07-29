import AppKit

/// The three capture modes, as a row of pressable cards: **icon above, label below**.
///
/// This replaces an `NSSegmentedControl`. A segmented control can only put a segment's image *beside*
/// its label, and at the popover's width that squeezes the text until "Webcam Only" truncates — so the
/// control read as an ambiguous strip of words rather than three buttons. Stacking the glyph over the
/// label gives each mode room for its full name, makes the icon the thing you scan for, and looks like
/// something you press.
///
/// It keeps the small piece of the segmented-control API the popover actually used —
/// `selectedSegment` plus a target/action — so the surrounding logic is unchanged.
@available(macOS 12.3, *)
final class ModeSelector: NSView {

    struct Mode {
        let title: String
        let symbol: String
        let tooltip: String
    }

    private var cards: [Card] = []
    private weak var target: AnyObject?
    private var action: Selector?

    /// Index of the selected mode. Setting it only repaints; it does not fire the action.
    var selectedSegment: Int = 0 {
        didSet { updateSelection() }
    }

    init(modes: [Mode], target: AnyObject?, action: Selector?) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for (i, mode) in modes.enumerated() {
            let card = Card(mode: mode)
            card.onClick = { [weak self] in self?.select(i) }
            cards.append(card)
            row.addArrangedSubview(card)
        }
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func select(_ index: Int) {
        guard index != selectedSegment else { return }
        selectedSegment = index
        if let action = action, let target = target {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func updateSelection() {
        for (i, card) in cards.enumerated() { card.isSelected = (i == selectedSegment) }
    }

    /// One mode card: a glyph, the label under it, and a selected state.
    private final class Card: NSView {
        var onClick: (() -> Void)?
        var isSelected = false { didSet { restyle() } }

        private let glyph = NSImageView()
        private let label = NSTextField(labelWithString: "")
        private var hovering = false
        private var tracking: NSTrackingArea?

        init(mode: Mode) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.borderWidth = 1
            toolTip = mode.tooltip

            let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            let image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title)
            image?.isTemplate = true
            glyph.image = image?.withSymbolConfiguration(config)
            glyph.translatesAutoresizingMaskIntoConstraints = false

            label.stringValue = mode.title
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false

            let stack = NSStackView(views: [glyph, label])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 3
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
                heightAnchor.constraint(equalToConstant: 56),
            ])
            restyle()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            tracking = t
        }

        override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
        override func mouseExited(with event: NSEvent) { hovering = false; restyle() }
        override func mouseDown(with event: NSEvent) { onClick?() }

        override func resetCursorRects() {
            // A pointing hand says "press me" — the same signal a link or button gives.
            addCursorRect(bounds, cursor: .pointingHand)
        }

        /// Selection is carried by the accent fill; hover only lifts the card slightly, so the
        /// selected mode is never ambiguous.
        private func restyle() {
            if isSelected {
                layer?.backgroundColor = Theme.accent.withAlphaComponent(0.16).cgColor
                layer?.borderColor = Theme.accent.cgColor
                glyph.contentTintColor = Theme.accent
                label.textColor = Theme.accent
            } else {
                layer?.backgroundColor = hovering
                    ? Theme.card.cgColor
                    : Theme.card.withAlphaComponent(0.55).cgColor
                layer?.borderColor = hovering ? Theme.strokeStrong.cgColor : Theme.stroke.cgColor
                glyph.contentTintColor = Theme.dim
                label.textColor = Theme.ink
            }
        }

        override func updateLayer() {
            super.updateLayer()
            restyle()   // re-resolve dynamic colours when light/dark changes
        }
    }
}
