import AppKit

/// Settings window for DemoTape's opt-in AI features (bring-your-own-key).
///
/// Captions and Voiceover are **independent** features — you can enable either, both, or
/// neither. Both are off by default; a feature can only be switched on once its key is present
/// and (ideally) verified with the Test button. API keys go straight to the macOS Keychain —
/// never to disk or UserDefaults — and are read only when a feature is enabled.
@available(macOS 12.3, *)
final class AISettingsController: NSObject, NSWindowDelegate {

    struct Provider { let name: String; let baseURL: String; let model: String; let keysURL: String }
    static let providers: [Provider] = [
        Provider(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "whisper-1",
                 keysURL: "https://platform.openai.com/api-keys"),
        Provider(name: "Groq",   baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3",
                 keysURL: "https://console.groq.com/keys"),
        Provider(name: "Custom", baseURL: "", model: "", keysURL: "")
    ]
    private static let elevenKeysURL = "https://elevenlabs.io/app/settings/api-keys"

    private var window: NSWindow?

    // Captions (STT)
    private var captionsEnableBox: NSButton!
    private var providerPopup: NSPopUpButton!
    private var keyField: SecureKeyField!
    private var baseField: NSTextField!
    private var modelField: NSTextField!
    private var langField: NSTextField!
    private var sttSavedBadge: NSTextField!
    private var sttRemoveButton: NSButton!
    private var sttKeyLink: NSButton!
    private var sttTestButton: NSButton!
    private var sttTestResult: NSTextField!
    private var verifiedSTT = false

    // Voiceover (ElevenLabs)
    private var voiceoverEnableBox: NSButton!
    private var elevenKeyField: SecureKeyField!
    private var elevenSavedBadge: NSTextField!
    private var elevenRemoveButton: NSButton!
    private var elevenTestButton: NSButton!
    private var elevenTestResult: NSTextField!
    private var verifiedEleven = false

    // Avatar (HeyGen)
    private var heygenKeyField: SecureKeyField!
    private var heygenSavedBadge: NSTextField!
    private var heygenRemoveButton: NSButton!
    private var heygenTestButton: NSButton!
    private var heygenTestResult: NSTextField!

    private var statusLabel: NSTextField!

    private let w: CGFloat = 520
    private let leftX: CGFloat = 28
    private let fieldX: CGFloat = 150
    private var fieldW: CGFloat { w - fieldX - 28 }

    func show() {
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let h: CGFloat = 860
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI Features"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        var y = h - 38

        // ===== Captions =====
        y = addSectionHeader("Captions", subtitle: "Transcribe recordings into subtitles.", at: y, on: content)

        captionsEnableBox = NSButton(checkboxWithTitle: "  Enable captions",
                                     target: self, action: #selector(toggleCaptions))
        captionsEnableBox.frame = NSRect(x: leftX, y: y - 22, width: w - 48, height: 22)
        content.addSubview(captionsEnableBox)
        y -= 38

        addLabel("Provider", y: y - 4, at: leftX, on: content)
        providerPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y - 8, width: fieldW, height: 26))
        providerPopup.addItems(withTitles: Self.providers.map { $0.name })
        providerPopup.selectItem(withTitle: Settings.aiProvider)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        content.addSubview(providerPopup)
        y -= 32

        sttKeyLink = linkButton(title: "Get an API key ↗", action: #selector(openSTTKeyPage))
        sttKeyLink.frame = NSRect(x: fieldX, y: y, width: 160, height: 16)
        content.addSubview(sttKeyLink)
        y -= 24

        addLabel("API key", y: y - 4, at: leftX, on: content)
        keyField = SecureKeyField(frame: NSRect(x: fieldX, y: y - 8, width: fieldW, height: 26))
        keyField.placeholderString = "sk-…  /  gsk_…"
        keyField.markStored(Keychain.get(account: Keychain.sttAPIKeyAccount) != nil)
        keyField.onChange = { [weak self] in self?.refreshCaptionsAvailability() }
        content.addSubview(keyField)
        y -= 30

        (sttSavedBadge, sttRemoveButton) = addSavedRow(
            at: y, on: content, stored: Keychain.get(account: Keychain.sttAPIKeyAccount) != nil,
            removeAction: #selector(removeSTTKey))
        y -= 28

        (sttTestButton, sttTestResult) = addTestRow(at: y, on: content, action: #selector(testSTTKey))
        y -= 32

        addLabel("Base URL", y: y - 4, at: leftX, on: content)
        baseField = NSTextField(frame: NSRect(x: fieldX, y: y - 8, width: fieldW, height: 24))
        baseField.stringValue = Settings.sttBaseURL
        baseField.placeholderString = "https://api.openai.com/v1"
        content.addSubview(baseField)
        y -= 32

        addLabel("Model", y: y - 4, at: leftX, on: content)
        modelField = NSTextField(frame: NSRect(x: fieldX, y: y - 8, width: fieldW, height: 24))
        modelField.stringValue = Settings.sttModel
        modelField.placeholderString = "whisper-1"
        content.addSubview(modelField)
        y -= 32

        addLabel("Language (opt.)", y: y - 4, at: leftX, on: content)
        langField = NSTextField(frame: NSRect(x: fieldX, y: y - 8, width: 110, height: 24))
        langField.stringValue = Settings.sttLanguage
        langField.placeholderString = "auto"
        content.addSubview(langField)
        let langHint = NSTextField(labelWithString: "ISO code, e.g. en, es, fr")
        langHint.font = .systemFont(ofSize: 10)
        langHint.textColor = .tertiaryLabelColor
        langHint.frame = NSRect(x: fieldX + 120, y: y - 4, width: 180, height: 16)
        content.addSubview(langHint)
        y -= 34

        let divider = NSBox(frame: NSRect(x: leftX, y: y, width: w - leftX - 28, height: 1))
        divider.boxType = .separator
        content.addSubview(divider)
        y -= 18

        // ===== Voiceover =====
        y = addSectionHeader("Voiceover", subtitle: "Narration powered by ElevenLabs.", at: y, on: content)

        voiceoverEnableBox = NSButton(checkboxWithTitle: "  Enable voiceover",
                                      target: self, action: #selector(toggleVoiceover))
        voiceoverEnableBox.frame = NSRect(x: leftX, y: y - 22, width: w - 48, height: 22)
        content.addSubview(voiceoverEnableBox)
        y -= 38

        let voLink = linkButton(title: "Get an API key ↗", action: #selector(openElevenKeyPage))
        voLink.frame = NSRect(x: fieldX, y: y, width: 160, height: 16)
        content.addSubview(voLink)
        y -= 24

        addLabel("API key", y: y - 4, at: leftX, on: content)
        elevenKeyField = SecureKeyField(frame: NSRect(x: fieldX, y: y - 8, width: fieldW, height: 26))
        elevenKeyField.placeholderString = "sk_…"
        elevenKeyField.markStored(Keychain.get(account: Keychain.elevenAPIKeyAccount) != nil)
        elevenKeyField.onChange = { [weak self] in self?.refreshVoiceoverAvailability() }
        content.addSubview(elevenKeyField)
        y -= 30

        (elevenSavedBadge, elevenRemoveButton) = addSavedRow(
            at: y, on: content, stored: Keychain.get(account: Keychain.elevenAPIKeyAccount) != nil,
            removeAction: #selector(removeElevenKey))
        y -= 28

        (elevenTestButton, elevenTestResult) = addTestRow(at: y, on: content, action: #selector(testElevenKey))
        y -= 30

        let divider2 = NSBox(frame: NSRect(x: leftX, y: y, width: w - leftX - 28, height: 1))
        divider2.boxType = .separator
        content.addSubview(divider2)
        y -= 18

        // ===== Avatar (HeyGen) =====
        y = addSectionHeader("Avatar Presenter", subtitle: "Photorealistic presenter via HeyGen — paid, best for short clips.",
                             at: y, on: content)
        let hgLink = linkButton(title: "Get an API key ↗", action: #selector(openHeyGenKeyPage))
        hgLink.frame = NSRect(x: fieldX, y: y - 4, width: 160, height: 16)
        content.addSubview(hgLink)
        y -= 26

        addLabel("API key", y: y - 4, at: leftX, on: content)
        heygenKeyField = SecureKeyField(frame: NSRect(x: fieldX, y: y - 8, width: fieldW, height: 26))
        heygenKeyField.placeholderString = "HeyGen API key"
        heygenKeyField.markStored(Keychain.get(account: Keychain.heygenAPIKeyAccount) != nil)
        content.addSubview(heygenKeyField)
        y -= 30

        (heygenSavedBadge, heygenRemoveButton) = addSavedRow(
            at: y, on: content, stored: Keychain.get(account: Keychain.heygenAPIKeyAccount) != nil,
            removeAction: #selector(removeHeyGenKey))
        y -= 28

        (heygenTestButton, heygenTestResult) = addTestRow(at: y, on: content, action: #selector(testHeyGenKey))
        y -= 34

        // Keychain reassurance.
        let shield = NSImageView(frame: NSRect(x: leftX, y: y - 22, width: 16, height: 16))
        shield.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Secure")
        shield.contentTintColor = .secondaryLabelColor
        content.addSubview(shield)
        let reassure = NSTextField(wrappingLabelWithString:
            "Keys are stored in your macOS Keychain — never written to disk, and sent only to the "
            + "provider you choose, when you test or use a feature.")
        reassure.font = .systemFont(ofSize: 10)
        reassure.textColor = .secondaryLabelColor
        reassure.frame = NSRect(x: leftX + 22, y: y - 30, width: w - leftX - 22 - 28, height: 30)
        content.addSubview(reassure)

        // ===== Footer =====
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: leftX, y: 24, width: 240, height: 18)
        content.addSubview(statusLabel)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: w - 124, y: 18, width: 96, height: 32)
        content.addSubview(save)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeWindow))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: w - 224, y: 18, width: 96, height: 32)
        content.addSubview(cancel)

        window.contentView = content
        self.window = window

        // Initial state reflects what's stored.
        verifiedSTT = Keychain.get(account: Keychain.sttAPIKeyAccount) != nil
        verifiedEleven = Keychain.get(account: Keychain.elevenAPIKeyAccount) != nil
        captionsEnableBox.state = Settings.captionsEnabled ? .on : .off
        voiceoverEnableBox.state = Settings.voiceoverEnabled ? .on : .off
        providerChanged()
        refreshCaptionsAvailability()
        refreshVoiceoverAvailability()

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout helpers

    private func addSectionHeader(_ title: String, subtitle: String, at y: CGFloat, on view: NSView) -> CGFloat {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 16, weight: .semibold)
        header.frame = NSRect(x: leftX, y: y - 22, width: w - 48, height: 24)
        view.addSubview(header)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: leftX, y: y - 38, width: w - 48, height: 16)
        view.addSubview(subtitleLabel)
        return y - 44
    }

    private func addLabel(_ text: String, y: CGFloat, at x: CGFloat, on view: NSView) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.alignment = .right
        l.frame = NSRect(x: x, y: y, width: 110, height: 18)
        view.addSubview(l)
    }

    private func linkButton(title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 11)])
        return b
    }

    private func addSavedRow(at y: CGFloat, on view: NSView, stored: Bool,
                             removeAction: Selector) -> (NSTextField, NSButton) {
        let badge = NSTextField(labelWithString: "✓ Saved in Keychain")
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .systemGreen
        badge.frame = NSRect(x: fieldX, y: y, width: 160, height: 16)
        badge.isHidden = !stored
        view.addSubview(badge)

        let remove = NSButton(title: "Remove", target: self, action: removeAction)
        remove.isBordered = false
        remove.attributedTitle = NSAttributedString(string: "Remove", attributes: [
            .foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 11)])
        remove.frame = NSRect(x: fieldX + 150, y: y - 2, width: 70, height: 18)
        remove.isHidden = !stored
        view.addSubview(remove)
        return (badge, remove)
    }

    private func addTestRow(at y: CGFloat, on view: NSView, action: Selector) -> (NSButton, NSTextField) {
        let test = NSButton(title: "Test key", target: self, action: action)
        test.bezelStyle = .rounded
        test.controlSize = .small
        test.frame = NSRect(x: fieldX, y: y - 4, width: 90, height: 22)
        view.addSubview(test)

        let result = NSTextField(labelWithString: "")
        result.font = .systemFont(ofSize: 11)
        result.textColor = .secondaryLabelColor
        result.lineBreakMode = .byTruncatingTail
        result.frame = NSRect(x: fieldX + 98, y: y - 2, width: fieldW - 98, height: 18)
        view.addSubview(result)
        return (test, result)
    }

    // MARK: - Availability gating

    private func sttKeyAvailable() -> Bool {
        verifiedSTT || Keychain.get(account: Keychain.sttAPIKeyAccount) != nil
            || !keyField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private func elevenKeyAvailable() -> Bool {
        verifiedEleven || Keychain.get(account: Keychain.elevenAPIKeyAccount) != nil
            || !elevenKeyField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The captions toggle only becomes interactive when a key is present; otherwise it's
    /// forced off, so the feature can't be enabled without a key.
    private func refreshCaptionsAvailability() {
        let available = sttKeyAvailable()
        captionsEnableBox.isEnabled = available
        if !available { captionsEnableBox.state = .off }
        captionsEnableBox.toolTip = available ? nil : "Add and test a key to enable captions."
        sttTestButton.isEnabled = available
        sttTestButton.toolTip = available ? nil : "Enter a key first."
    }
    private func refreshVoiceoverAvailability() {
        let available = elevenKeyAvailable()
        voiceoverEnableBox.isEnabled = available
        if !available { voiceoverEnableBox.state = .off }
        voiceoverEnableBox.toolTip = available ? nil : "Add and test a key to enable voiceover."
        elevenTestButton.isEnabled = available
        elevenTestButton.toolTip = available ? nil : "Enter a key first."
    }

    // MARK: - Actions

    @objc private func toggleCaptions() {}
    @objc private func toggleVoiceover() {}

    @objc private func providerChanged() {
        guard let name = providerPopup.selectedItem?.title,
              let p = Self.providers.first(where: { $0.name == name }) else { return }
        if p.name != "Custom" {
            baseField.stringValue = p.baseURL
            modelField.stringValue = p.model
        }
        sttKeyLink.isHidden = p.keysURL.isEmpty
    }

    @objc private func openSTTKeyPage() {
        guard let name = providerPopup.selectedItem?.title,
              let p = Self.providers.first(where: { $0.name == name }),
              !p.keysURL.isEmpty, let url = URL(string: p.keysURL) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func openElevenKeyPage() {
        if let url = URL(string: Self.elevenKeysURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func removeSTTKey() {
        Keychain.remove(account: Keychain.sttAPIKeyAccount)
        keyField.stringValue = ""
        verifiedSTT = false
        sttSavedBadge.isHidden = true
        sttRemoveButton.isHidden = true
        sttTestResult.stringValue = ""
        Settings.captionsEnabled = false
        refreshCaptionsAvailability()
        status("Captions key removed.", .secondaryLabelColor)
    }
    @objc private func removeElevenKey() {
        Keychain.remove(account: Keychain.elevenAPIKeyAccount)
        elevenKeyField.stringValue = ""
        verifiedEleven = false
        elevenSavedBadge.isHidden = true
        elevenRemoveButton.isHidden = true
        elevenTestResult.stringValue = ""
        Settings.voiceoverEnabled = false
        refreshVoiceoverAvailability()
        status("Voiceover key removed.", .secondaryLabelColor)
    }

    @objc private func openHeyGenKeyPage() {
        if let url = URL(string: "https://app.heygen.com/settings") { NSWorkspace.shared.open(url) }
    }

    @objc private func removeHeyGenKey() {
        Keychain.remove(account: Keychain.heygenAPIKeyAccount)
        heygenKeyField.stringValue = ""
        heygenSavedBadge.isHidden = true
        heygenRemoveButton.isHidden = true
        heygenTestResult.stringValue = ""
        status("HeyGen key removed.", .secondaryLabelColor)
    }

    @objc private func testHeyGenKey() {
        let typed = heygenKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (Keychain.get(account: Keychain.heygenAPIKeyAccount) ?? "") : typed
        guard !key.isEmpty else { heygenTestResult.textColor = .systemRed; heygenTestResult.stringValue = "✗ Enter a key first."; return }
        heygenTestButton.isEnabled = false
        heygenTestResult.textColor = .secondaryLabelColor
        heygenTestResult.stringValue = "Testing…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok: Bool
            var count = 0
            do { count = try HeyGenAvatarProvider(apiKey: key).listAvatars().count; ok = true }
            catch { ok = false }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.heygenTestButton.isEnabled = true
                if ok {
                    if !typed.isEmpty { Keychain.set(typed, account: Keychain.heygenAPIKeyAccount) }
                    self.heygenSavedBadge.isHidden = false
                    self.heygenRemoveButton.isHidden = false
                    self.heygenTestResult.textColor = .systemGreen
                    self.heygenTestResult.stringValue = "✓ Key verified (\(count) avatars)."
                } else {
                    self.heygenTestResult.textColor = .systemRed
                    self.heygenTestResult.stringValue = "✗ Key rejected by HeyGen."
                }
            }
        }
    }

    @objc private func testSTTKey() {
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (Keychain.get(account: Keychain.sttAPIKeyAccount) ?? "") : typed
        let base = baseField.stringValue.trimmingCharacters(in: .whitespaces)
        sttTestButton.isEnabled = false
        sttTestResult.textColor = .secondaryLabelColor
        sttTestResult.stringValue = "Testing…"
        KeyTester.testSTT(baseURL: base, apiKey: key) { [weak self] result in
            guard let self = self else { return }
            self.sttTestButton.isEnabled = true
            self.handle(result, on: self.sttTestResult) {
                // On success, persist a freshly typed key and enable the feature.
                if !typed.isEmpty { Keychain.set(typed, account: Keychain.sttAPIKeyAccount) }
                self.verifiedSTT = true
                self.sttSavedBadge.isHidden = false
                self.sttRemoveButton.isHidden = false
                self.refreshCaptionsAvailability()
                self.captionsEnableBox.state = .on
            }
        }
    }

    @objc private func testElevenKey() {
        let typed = elevenKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (Keychain.get(account: Keychain.elevenAPIKeyAccount) ?? "") : typed
        elevenTestButton.isEnabled = false
        elevenTestResult.textColor = .secondaryLabelColor
        elevenTestResult.stringValue = "Testing…"
        KeyTester.testElevenLabs(apiKey: key) { [weak self] result in
            guard let self = self else { return }
            self.elevenTestButton.isEnabled = true
            self.handle(result, on: self.elevenTestResult) {
                if !typed.isEmpty { Keychain.set(typed, account: Keychain.elevenAPIKeyAccount) }
                self.verifiedEleven = true
                self.elevenSavedBadge.isHidden = false
                self.elevenRemoveButton.isHidden = false
                self.refreshVoiceoverAvailability()
                self.voiceoverEnableBox.state = .on
            }
        }
    }

    private func handle(_ result: KeyTester.Result, on label: NSTextField, onOK: () -> Void) {
        switch result {
        case .ok(let msg):
            label.textColor = .systemGreen
            label.stringValue = "✓ " + msg
            onOK()
        case .invalid(let msg):
            label.textColor = .systemRed
            label.stringValue = "✗ " + msg
        case .failed(let msg):
            label.textColor = .systemOrange
            label.stringValue = "⚠︎ " + msg
        }
    }

    @objc private func save() {
        Settings.aiProvider = providerPopup.selectedItem?.title ?? "OpenAI"
        Settings.sttBaseURL = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.sttModel = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.sttLanguage = langField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // A typed value replaces the stored key; blank leaves it untouched (removal is explicit).
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Keychain.set(key, account: Keychain.sttAPIKeyAccount) }
        let voKey = elevenKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !voKey.isEmpty { Keychain.set(voKey, account: Keychain.elevenAPIKeyAccount) }
        let hgKey = heygenKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hgKey.isEmpty { Keychain.set(hgKey, account: Keychain.heygenAPIKeyAccount) }

        // Persist per-feature enablement — only if a key is actually available.
        Settings.captionsEnabled = (captionsEnableBox.state == .on) && sttKeyAvailable()
            && Keychain.get(account: Keychain.sttAPIKeyAccount) != nil
        Settings.voiceoverEnabled = (voiceoverEnableBox.state == .on) && elevenKeyAvailable()
            && Keychain.get(account: Keychain.elevenAPIKeyAccount) != nil

        closeWindow()
    }

    private func status(_ text: String, _ color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    @objc private func closeWindow() { window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil }
}
