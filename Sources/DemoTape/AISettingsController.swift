import AppKit

/// Settings window for DemoTape's opt-in AI features (bring-your-own-key).
///
/// The app is fully local until AI is enabled here and a key is saved. The API key goes
/// straight to the Keychain; everything else is normal preferences. Picking a provider
/// preset auto-fills the base URL and a sensible default model.
@available(macOS 12.3, *)
final class AISettingsController: NSObject, NSWindowDelegate {

    /// Known OpenAI-compatible speech-to-text providers. "Custom" leaves the fields editable
    /// for local Whisper servers or other compatible endpoints.
    struct Provider { let name: String; let baseURL: String; let model: String }
    static let providers: [Provider] = [
        Provider(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "whisper-1"),
        Provider(name: "Groq",   baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3"),
        Provider(name: "Custom", baseURL: "", model: "")
    ]

    private var window: NSWindow?
    private var enableBox: NSButton!
    private var providerPopup: NSPopUpButton!
    private var keyField: NSSecureTextField!
    private var baseField: NSTextField!
    private var modelField: NSTextField!
    private var langField: NSTextField!
    private var statusLabel: NSTextField!

    func show() {
        let w: CGFloat = 500, h: CGFloat = 388
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI Features"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let leftX: CGFloat = 24
        let fieldX: CGFloat = 150
        let fieldW: CGFloat = w - fieldX - 24

        // Header.
        let header = NSTextField(labelWithString: "Speech-to-Text (Captions)")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.frame = NSRect(x: leftX, y: h - 44, width: w - 48, height: 22)
        content.addSubview(header)

        let sub = NSTextField(wrappingLabelWithString:
            "Bring your own key. DemoTape stays local until you enable this — audio is sent only "
            + "to the endpoint you choose, using your key. The key is stored in your Keychain.")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: leftX, y: h - 92, width: w - 48, height: 40)
        content.addSubview(sub)

        // Enable toggle.
        enableBox = NSButton(checkboxWithTitle: "  Enable AI features",
                             target: self, action: #selector(toggleEnabled))
        enableBox.state = Settings.aiEnabled ? .on : .off
        enableBox.frame = NSRect(x: leftX, y: h - 126, width: w - 48, height: 22)
        content.addSubview(enableBox)

        // Provider.
        addLabel("Provider", y: h - 168, at: leftX, on: content)
        providerPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: h - 172, width: fieldW, height: 26))
        providerPopup.addItems(withTitles: Self.providers.map { $0.name })
        providerPopup.selectItem(withTitle: Settings.aiProvider)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        content.addSubview(providerPopup)

        // API key.
        addLabel("API key", y: h - 208, at: leftX, on: content)
        keyField = NSSecureTextField(frame: NSRect(x: fieldX, y: h - 212, width: fieldW, height: 24))
        keyField.placeholderString = "sk-…  /  gsk_…"
        if let existing = Keychain.get(account: Keychain.sttAPIKeyAccount) { keyField.stringValue = existing }
        content.addSubview(keyField)

        // Base URL.
        addLabel("Base URL", y: h - 244, at: leftX, on: content)
        baseField = NSTextField(frame: NSRect(x: fieldX, y: h - 248, width: fieldW, height: 24))
        baseField.stringValue = Settings.sttBaseURL
        baseField.placeholderString = "https://api.openai.com/v1"
        content.addSubview(baseField)

        // Model.
        addLabel("Model", y: h - 280, at: leftX, on: content)
        modelField = NSTextField(frame: NSRect(x: fieldX, y: h - 284, width: fieldW, height: 24))
        modelField.stringValue = Settings.sttModel
        modelField.placeholderString = "whisper-1"
        content.addSubview(modelField)

        // Language.
        addLabel("Language (opt.)", y: h - 316, at: leftX, on: content)
        langField = NSTextField(frame: NSRect(x: fieldX, y: h - 320, width: 120, height: 24))
        langField.stringValue = Settings.sttLanguage
        langField.placeholderString = "auto"
        content.addSubview(langField)
        let langHint = NSTextField(labelWithString: "ISO code, e.g. en, es, fr")
        langHint.font = .systemFont(ofSize: 10)
        langHint.textColor = .tertiaryLabelColor
        langHint.frame = NSRect(x: fieldX + 130, y: h - 316, width: 180, height: 16)
        content.addSubview(langHint)

        // Status + buttons.
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: leftX, y: 24, width: 220, height: 18)
        content.addSubview(statusLabel)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: w - 120, y: 18, width: 96, height: 32)
        content.addSubview(save)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeWindow))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: w - 220, y: 18, width: 96, height: 32)
        content.addSubview(cancel)

        window.contentView = content
        self.window = window
        applyEnabledState()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func addLabel(_ text: String, y: CGFloat, at x: CGFloat, on view: NSView) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.alignment = .right
        l.frame = NSRect(x: x, y: y, width: 110, height: 18)
        view.addSubview(l)
    }

    @objc private func toggleEnabled() { applyEnabledState() }

    private func applyEnabledState() {
        let on = enableBox.state == .on
        [providerPopup, keyField, baseField, modelField, langField].forEach { $0?.isEnabled = on }
    }

    @objc private func providerChanged() {
        guard let name = providerPopup.selectedItem?.title,
              let p = Self.providers.first(where: { $0.name == name }) else { return }
        if p.name != "Custom" {
            baseField.stringValue = p.baseURL
            modelField.stringValue = p.model
        }
    }

    @objc private func save() {
        Settings.aiEnabled = (enableBox.state == .on)
        Settings.aiProvider = providerPopup.selectedItem?.title ?? "OpenAI"
        Settings.sttBaseURL = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.sttModel = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.sttLanguage = langField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            Keychain.remove(account: Keychain.sttAPIKeyAccount)
        } else {
            Keychain.set(key, account: Keychain.sttAPIKeyAccount)
        }

        if Settings.aiEnabled && key.isEmpty {
            statusLabel.stringValue = "Enabled, but no key saved yet."
            statusLabel.textColor = .systemOrange
            return
        }
        closeWindow()
    }

    @objc private func closeWindow() { window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil }
}
