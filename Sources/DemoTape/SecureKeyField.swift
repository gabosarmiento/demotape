import AppKit

/// A polished secret-entry control for API keys: a masked field with a show/hide reveal
/// toggle and a subtle lock glyph, so entering a key feels deliberate and secure.
///
/// It never displays a stored secret back to the user. When a key already exists it shows a
/// "saved" placeholder; typing a new value replaces it, and leaving it blank keeps the stored
/// key untouched (use `markStored`/the caller's Remove button to clear).
@available(macOS 12.3, *)
final class SecureKeyField: NSView, NSTextFieldDelegate {

    private let secureField = NSSecureTextField()
    private let plainField = NSTextField()
    private let revealButton = NSButton()
    private let lockIcon = NSImageView()
    private var revealed = false

    /// Called whenever the typed value changes (either field), so callers can update UI live.
    var onChange: (() -> Void)?

    /// The typed value (from whichever field is currently visible). Empty when untouched.
    var stringValue: String {
        get { revealed ? plainField.stringValue : secureField.stringValue }
        set { secureField.stringValue = newValue; plainField.stringValue = newValue }
    }

    var placeholderString: String? {
        didSet {
            secureField.placeholderString = placeholderString
            plainField.placeholderString = placeholderString
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        let h = bounds.height
        let lockW: CGFloat = 22
        let eyeW: CGFloat = 28
        let fieldW = bounds.width - lockW - eyeW - 6

        // Leading lock glyph — quiet reassurance that this is a secret.
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure")
        lockIcon.contentTintColor = .tertiaryLabelColor
        lockIcon.imageScaling = .scaleProportionallyDown
        lockIcon.frame = NSRect(x: 0, y: (h - 14) / 2, width: lockW, height: 14)
        addSubview(lockIcon)

        let fieldX = lockW + 2
        let common: (NSTextField) -> Void = { f in
            f.frame = NSRect(x: fieldX, y: 0, width: fieldW, height: h)
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.lineBreakMode = .byTruncatingTail
        }
        common(secureField)
        common(plainField)
        plainField.isHidden = true
        secureField.delegate = self
        plainField.delegate = self
        addSubview(secureField)
        addSubview(plainField)

        // Reveal toggle.
        revealButton.frame = NSRect(x: fieldX + fieldW + 4, y: (h - 22) / 2, width: eyeW, height: 22)
        revealButton.bezelStyle = .roundRect
        revealButton.isBordered = false
        revealButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show key")
        revealButton.imagePosition = .imageOnly
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)
        revealButton.toolTip = "Show or hide the key"
        addSubview(revealButton)
    }

    @objc private func toggleReveal() {
        // Sync value across before swapping which field is visible.
        if revealed { secureField.stringValue = plainField.stringValue }
        else { plainField.stringValue = secureField.stringValue }
        revealed.toggle()
        secureField.isHidden = revealed
        plainField.isHidden = !revealed
        let symbol = revealed ? "eye.slash" : "eye"
        revealButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle key visibility")
        window?.makeFirstResponder(revealed ? plainField : secureField)
    }

    /// Shows a masked "already saved" placeholder without ever exposing the stored secret.
    func markStored(_ stored: Bool) {
        if stored, (placeholderString == nil || !(placeholderString?.contains("saved") ?? false)) {
            let hint = "•••••••••••••••• (saved — type to replace)"
            secureField.placeholderString = hint
            plainField.placeholderString = hint
        }
    }

    func setEnabled(_ enabled: Bool) {
        secureField.isEnabled = enabled
        plainField.isEnabled = enabled
        revealButton.isEnabled = enabled
        lockIcon.contentTintColor = enabled ? .tertiaryLabelColor : .quaternaryLabelColor
    }

    // Keep the two fields in sync as the user types, and notify the owner live.
    func controlTextDidChange(_ notification: Notification) {
        if revealed { secureField.stringValue = plainField.stringValue }
        else { plainField.stringValue = secureField.stringValue }
        onChange?()
    }
}
