import AppKit

/// A flipped container so tab content can be laid out top-down (y grows downward).
@available(macOS 12.3, *)
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Settings window for DemoTape's opt-in AI features (bring-your-own-key).
///
/// Captions and Voiceover are **independent** features — you can enable either, both, or
/// neither. Both are off by default; a feature can only be switched on once its key is present
/// and (ideally) verified with the Test button. API keys go straight to the macOS Keychain —
/// never to disk or UserDefaults — and are read only when a feature is enabled.
///
/// The three providers live on their own **tabs** (Captions / Voiceover / Avatar Presenter) so
/// each one is a short, focused form instead of one long scroll.
@available(macOS 12.3, *)
final class AISettingsController: NSObject, NSWindowDelegate {

    struct Provider { let name: String; let baseURL: String; let model: String; let keysURL: String }
    static let providers: [Provider] = [
        Provider(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "whisper-1",
                 keysURL: "https://platform.openai.com/api-keys"),
        Provider(name: "Groq",   baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3",
                 keysURL: "https://console.groq.com/keys"),
        // Local, free, offline — point at a self-hosted OpenAI-compatible STT server (e.g.
        // faster-whisper-server / speaches / LocalAI). No key needed. See tools/tts-shim README.
        Provider(name: "Local (OpenAI-compatible)", baseURL: "http://localhost:8000/v1",
                 model: "Systran/faster-whisper-base.en", keysURL: ""),
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

    // Voiceover (TTS — ElevenLabs, OpenAI-compatible local, or custom)
    private var voiceoverEnableBox: NSButton!
    private var ttsProviderPopup: NSPopUpButton!
    private var voKeyLink: NSButton!
    private var elevenKeyField: SecureKeyField!
    private var elevenSavedBadge: NSTextField!
    private var elevenRemoveButton: NSButton!
    private var elevenTestButton: NSButton!
    private var elevenTestResult: NSTextField!
    private var verifiedEleven = false
    private var ttsBaseField: NSTextField!
    private var ttsModelField: NSTextField!
    private var ttsVoiceField: NSTextField!
    private var voKeyRowViews: [NSView] = []     // key field + saved row + test row (hidden if provider needs no key)
    private var voLocalRowViews: [NSView] = []   // Base URL / Model / Voice (shown only for local/custom)

    /// TTS provider presets shown on the Voiceover tab.
    struct TTSPreset { let name: String; let baseURL: String; let model: String; let voice: String; let keysURL: String }
    static let ttsPresets: [TTSPreset] = [
        TTSPreset(name: "ElevenLabs", baseURL: "", model: "", voice: "",
                  keysURL: "https://elevenlabs.io/app/settings/api-keys"),
        TTSPreset(name: "OpenAI-compatible", baseURL: "http://localhost:8880/v1", model: "tts-1", voice: "alloy",
                  keysURL: ""),
        TTSPreset(name: "Custom", baseURL: "http://localhost:8000/speak", model: "", voice: "",
                  keysURL: "")
    ]

    // Avatar (HeyGen)
    private var heygenKeyField: SecureKeyField!
    private var heygenSavedBadge: NSTextField!
    private var heygenRemoveButton: NSButton!
    private var heygenTestButton: NSButton!
    private var heygenTestResult: NSTextField!

    private var statusLabel: NSTextField!

    private let w: CGFloat = 540
    private let tabW: CGFloat = 500     // inner width of a tab's content view
    private let labelW: CGFloat = 116
    private let fieldX: CGFloat = 128
    private var fieldW: CGFloat { tabW - fieldX - 12 }

    func show() {
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let h: CGFloat = 520
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI Features"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Tabs, one per provider.
        let tabView = NSTabView(frame: NSRect(x: 12, y: 92, width: w - 24, height: h - 92 - 12))
        tabView.addTabViewItem(makeCaptionsTab())
        tabView.addTabViewItem(makeVoiceoverTab())
        tabView.addTabViewItem(makeAvatarTab())
        content.addSubview(tabView)

        // Keychain reassurance (shared, above the footer).
        let shield = NSImageView(frame: NSRect(x: 20, y: 58, width: 16, height: 16))
        shield.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Secure")
        shield.contentTintColor = .secondaryLabelColor
        content.addSubview(shield)
        let reassure = NSTextField(wrappingLabelWithString:
            "Keys are stored in your macOS Keychain — never written to disk, and sent only to the "
            + "provider you choose, when you test or use a feature.")
        reassure.font = .systemFont(ofSize: 10)
        reassure.textColor = .secondaryLabelColor
        reassure.frame = NSRect(x: 42, y: 50, width: w - 42 - 20, height: 30)
        content.addSubview(reassure)

        // Footer.
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 20, width: 240, height: 18)
        content.addSubview(statusLabel)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: w - 124, y: 14, width: 96, height: 32)
        content.addSubview(save)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeWindow))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: w - 224, y: 14, width: 96, height: 32)
        content.addSubview(cancel)

        window.contentView = content
        self.window = window

        // Initial state reflects what's stored.
        verifiedSTT = Keychain.exists(account: Keychain.sttAPIKeyAccount)
        verifiedEleven = Keychain.exists(account: Keychain.elevenAPIKeyAccount)
        captionsEnableBox.state = Settings.captionsEnabled ? .on : .off
        voiceoverEnableBox.state = Settings.voiceoverEnabled ? .on : .off
        providerChanged()
        ttsProviderChanged()
        refreshCaptionsAvailability()
        refreshVoiceoverAvailability()

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        // Don't auto-focus a text field, so the first click on Save/Cancel isn't swallowed
        // by that field ending its editing session.
        window.initialFirstResponder = nil
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
    }

    // MARK: - Tabs

    private func makeCaptionsTab() -> NSTabViewItem {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 400))
        var y: CGFloat = 12
        y = tdSubtitle("Transcribe recordings into subtitles.", y: y, on: v)

        captionsEnableBox = NSButton(checkboxWithTitle: "  Enable captions",
                                     target: self, action: #selector(toggleCaptions))
        captionsEnableBox.frame = NSRect(x: 4, y: y, width: tabW - 8, height: 22)
        v.addSubview(captionsEnableBox)
        y += 34

        tdLabel("Provider", y: y, on: v)
        providerPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 26))
        providerPopup.addItems(withTitles: Self.providers.map { $0.name })
        providerPopup.selectItem(withTitle: Settings.aiProvider)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        v.addSubview(providerPopup)
        y += 34

        sttKeyLink = tdLink("Get an API key ↗", y: y, on: v, action: #selector(openSTTKeyPage))
        y += 22

        tdLabel("API key", y: y, on: v)
        keyField = SecureKeyField(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 26))
        keyField.placeholderString = "sk-…  /  gsk_…"
        keyField.markStored(Keychain.exists(account: Keychain.sttAPIKeyAccount))
        keyField.onChange = { [weak self] in self?.refreshCaptionsAvailability() }
        v.addSubview(keyField)
        y += 32

        (sttSavedBadge, sttRemoveButton) = tdSavedRow(
            y: y, on: v, stored: Keychain.exists(account: Keychain.sttAPIKeyAccount),
            removeAction: #selector(removeSTTKey))
        y += 24

        (sttTestButton, sttTestResult) = tdTestRow(y: y, on: v, action: #selector(testSTTKey))
        y += 36

        tdLabel("Base URL", y: y, on: v)
        baseField = NSTextField(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 24))
        baseField.stringValue = Settings.sttBaseURL
        baseField.placeholderString = "https://api.openai.com/v1"
        v.addSubview(baseField)
        y += 32

        tdLabel("Model", y: y, on: v)
        modelField = NSTextField(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 24))
        modelField.stringValue = Settings.sttModel
        modelField.placeholderString = "whisper-1"
        v.addSubview(modelField)
        y += 32

        tdLabel("Language (opt.)", y: y, on: v)
        langField = NSTextField(frame: NSRect(x: fieldX, y: y, width: 110, height: 24))
        langField.stringValue = Settings.sttLanguage
        langField.placeholderString = "auto"
        v.addSubview(langField)
        let langHint = NSTextField(labelWithString: "ISO code, e.g. en, es, fr")
        langHint.font = .systemFont(ofSize: 10)
        langHint.textColor = .tertiaryLabelColor
        langHint.frame = NSRect(x: fieldX + 120, y: y + 4, width: 180, height: 16)
        v.addSubview(langHint)

        let item = NSTabViewItem(identifier: "captions")
        item.label = "Captions"
        item.view = v
        return item
    }

    private func makeVoiceoverTab() -> NSTabViewItem {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 400))
        var y: CGFloat = 12
        y = tdSubtitle("Narration — pay for ElevenLabs, or run a local server for free.", y: y, on: v)

        voiceoverEnableBox = NSButton(checkboxWithTitle: "  Enable voiceover",
                                      target: self, action: #selector(toggleVoiceover))
        voiceoverEnableBox.frame = NSRect(x: 4, y: y, width: tabW - 8, height: 22)
        v.addSubview(voiceoverEnableBox)
        y += 34

        tdLabel("Provider", y: y, on: v)
        ttsProviderPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 26))
        ttsProviderPopup.addItems(withTitles: Self.ttsPresets.map { $0.name })
        ttsProviderPopup.selectItem(withTitle: Settings.ttsProvider)
        ttsProviderPopup.target = self
        ttsProviderPopup.action = #selector(ttsProviderChanged)
        v.addSubview(ttsProviderPopup)
        y += 34

        voKeyLink = tdLink("Get an API key ↗", y: y, on: v, action: #selector(openElevenKeyPage))
        y += 22

        // Key row (its label + field + saved/test rows are grouped so they can be hidden when a
        // local provider needs no key).
        let keyLabel = tdLabel("API key", y: y, on: v)
        elevenKeyField = SecureKeyField(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 26))
        elevenKeyField.placeholderString = "sk_…  (leave blank for a keyless local server)"
        elevenKeyField.markStored(Keychain.exists(account: Keychain.elevenAPIKeyAccount))
        elevenKeyField.onChange = { [weak self] in self?.refreshVoiceoverAvailability() }
        v.addSubview(elevenKeyField)
        y += 32

        (elevenSavedBadge, elevenRemoveButton) = tdSavedRow(
            y: y, on: v, stored: Keychain.exists(account: Keychain.elevenAPIKeyAccount),
            removeAction: #selector(removeElevenKey))
        y += 24

        (elevenTestButton, elevenTestResult) = tdTestRow(y: y, on: v, action: #selector(testElevenKey))
        y += 38
        voKeyRowViews = [keyLabel, elevenKeyField, elevenSavedBadge, elevenRemoveButton, elevenTestButton, elevenTestResult]

        // Local/custom-only rows: Base URL / Model / Voice.
        let baseLabel = tdLabel("Base URL", y: y, on: v)
        ttsBaseField = NSTextField(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 24))
        ttsBaseField.stringValue = Settings.ttsBaseURL
        ttsBaseField.placeholderString = "http://localhost:8880/v1"
        v.addSubview(ttsBaseField)
        y += 32

        let modelLabel = tdLabel("Model", y: y, on: v)
        ttsModelField = NSTextField(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 24))
        ttsModelField.stringValue = Settings.ttsModel
        ttsModelField.placeholderString = "tts-1"
        v.addSubview(ttsModelField)
        y += 32

        let voiceLabel = tdLabel("Voice", y: y, on: v)
        ttsVoiceField = NSTextField(frame: NSRect(x: fieldX, y: y, width: 160, height: 24))
        ttsVoiceField.stringValue = Settings.ttsVoice
        ttsVoiceField.placeholderString = "alloy"
        v.addSubview(ttsVoiceField)
        let voiceHint = NSTextField(labelWithString: "server voice name")
        voiceHint.font = .systemFont(ofSize: 10)
        voiceHint.textColor = .tertiaryLabelColor
        voiceHint.frame = NSRect(x: fieldX + 170, y: y + 4, width: 150, height: 16)
        v.addSubview(voiceHint)
        y += 32

        let localHint = NSTextField(wrappingLabelWithString:
            "Point at any OpenAI-compatible server (LocalAI, Kokoro-FastAPI, openedai-speech) — "
            + "run one in Docker for free, offline narration. See tools/tts-shim in the repo.")
        localHint.font = .systemFont(ofSize: 10)
        localHint.textColor = .secondaryLabelColor
        localHint.frame = NSRect(x: fieldX, y: y, width: fieldW, height: 30)
        v.addSubview(localHint)
        voLocalRowViews = [baseLabel, ttsBaseField, modelLabel, ttsModelField, voiceLabel, ttsVoiceField, voiceHint, localHint]

        let item = NSTabViewItem(identifier: "voiceover")
        item.label = "Voiceover"
        item.view = v
        return item
    }

    private func makeAvatarTab() -> NSTabViewItem {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 400))
        var y: CGFloat = 12
        y = tdSubtitle("Photorealistic presenter via HeyGen — paid, best for short clips.", y: y, on: v)
        y += 4

        _ = tdLink("Get an API key ↗", y: y, on: v, action: #selector(openHeyGenKeyPage))
        y += 24

        tdLabel("API key", y: y, on: v)
        heygenKeyField = SecureKeyField(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 26))
        heygenKeyField.placeholderString = "HeyGen API key"
        heygenKeyField.markStored(Keychain.exists(account: Keychain.heygenAPIKeyAccount))
        v.addSubview(heygenKeyField)
        y += 32

        (heygenSavedBadge, heygenRemoveButton) = tdSavedRow(
            y: y, on: v, stored: Keychain.exists(account: Keychain.heygenAPIKeyAccount),
            removeAction: #selector(removeHeyGenKey))
        y += 24

        (heygenTestButton, heygenTestResult) = tdTestRow(y: y, on: v, action: #selector(testHeyGenKey))

        let item = NSTabViewItem(identifier: "avatar")
        item.label = "Avatar Presenter"
        item.view = v
        return item
    }

    // MARK: - Layout helpers (flipped, top-down)

    private func tdSubtitle(_ text: String, y: CGFloat, on view: NSView) -> CGFloat {
        let s = NSTextField(labelWithString: text)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        s.frame = NSRect(x: 4, y: y, width: tabW - 8, height: 16)
        view.addSubview(s)
        return y + 26
    }

    @discardableResult
    private func tdLabel(_ text: String, y: CGFloat, on view: NSView) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.alignment = .right
        l.frame = NSRect(x: 0, y: y + 4, width: labelW, height: 18)
        view.addSubview(l)
        return l
    }

    private func linkButton(title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 11)])
        return b
    }

    private func tdLink(_ title: String, y: CGFloat, on view: NSView, action: Selector) -> NSButton {
        let b = linkButton(title: title, action: action)
        b.frame = NSRect(x: fieldX, y: y, width: 160, height: 16)
        view.addSubview(b)
        return b
    }

    private func tdSavedRow(y: CGFloat, on view: NSView, stored: Bool,
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
        remove.frame = NSRect(x: fieldX + 150, y: y - 1, width: 70, height: 18)
        remove.isHidden = !stored
        view.addSubview(remove)
        return (badge, remove)
    }

    private func tdTestRow(y: CGFloat, on view: NSView, action: Selector) -> (NSButton, NSTextField) {
        let test = NSButton(title: "Test key", target: self, action: action)
        test.bezelStyle = .rounded
        test.controlSize = .small
        test.frame = NSRect(x: fieldX, y: y, width: 90, height: 22)
        view.addSubview(test)

        let result = NSTextField(labelWithString: "")
        result.font = .systemFont(ofSize: 11)
        result.textColor = .secondaryLabelColor
        result.lineBreakMode = .byTruncatingTail
        result.frame = NSRect(x: fieldX + 98, y: y + 3, width: fieldW - 98, height: 18)
        view.addSubview(result)
        return (test, result)
    }

    // MARK: - Enable toggles (explicit — not gated on a key)

    /// Captions/Voiceover are enabled explicitly by the checkbox. If enabled without a key, the
    /// menu action prompts to add one — no confusing "type-to-enable" gating here.
    private func refreshCaptionsAvailability() {}
    private func refreshVoiceoverAvailability() {}

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
    /// The current TTS provider preset chosen on the Voiceover tab.
    private var currentTTSPreset: TTSPreset {
        let name = ttsProviderPopup?.selectedItem?.title ?? "ElevenLabs"
        return Self.ttsPresets.first(where: { $0.name == name }) ?? Self.ttsPresets[0]
    }
    /// Keychain account the Voiceover key field maps to for the selected provider.
    private var ttsKeyAccount: String {
        currentTTSPreset.name == "ElevenLabs" ? Keychain.elevenAPIKeyAccount : Keychain.ttsAPIKeyAccount
    }

    @objc private func ttsProviderChanged() {
        let p = currentTTSPreset
        let isEleven = (p.name == "ElevenLabs")
        // Local/custom rows only make sense off ElevenLabs.
        voLocalRowViews.forEach { $0.isHidden = isEleven }
        // Seed sensible defaults when switching to a local/custom preset (unless already set).
        if !isEleven {
            if ttsBaseField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { ttsBaseField.stringValue = p.baseURL }
            if p.name == "OpenAI-compatible" {
                if ttsModelField.stringValue.isEmpty { ttsModelField.stringValue = p.model }
                if ttsVoiceField.stringValue.isEmpty { ttsVoiceField.stringValue = p.voice }
            }
        }
        // The key link only applies where there's a hosted account to sign up for.
        voKeyLink.isHidden = p.keysURL.isEmpty
        // Rebind the shared key field/badges to the account this provider uses.
        let stored = Keychain.exists(account: ttsKeyAccount)
        elevenKeyField.stringValue = ""
        elevenKeyField.markStored(stored)
        elevenSavedBadge.isHidden = !stored
        elevenRemoveButton.isHidden = !stored
        elevenTestResult.stringValue = ""
        elevenKeyField.placeholderString = isEleven
            ? "sk_…" : "optional — many local servers need no key"
    }

    @objc private func openElevenKeyPage() {
        let s = currentTTSPreset.keysURL.isEmpty ? Self.elevenKeysURL : currentTTSPreset.keysURL
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    @objc private func removeSTTKey() {
        Keychain.remove(account: Keychain.sttAPIKeyAccount)
        keyField.stringValue = ""
        verifiedSTT = false
        sttSavedBadge.isHidden = true
        sttRemoveButton.isHidden = true
        sttTestResult.stringValue = ""
        Settings.captionsEnabled = false
        captionsEnableBox.state = .off
        refreshCaptionsAvailability()
        status("Captions key removed.", .secondaryLabelColor)
    }
    @objc private func removeElevenKey() {
        Keychain.remove(account: ttsKeyAccount)
        elevenKeyField.stringValue = ""
        verifiedEleven = false
        elevenSavedBadge.isHidden = true
        elevenRemoveButton.isHidden = true
        elevenTestResult.stringValue = ""
        // Only ElevenLabs strictly needs a key, so only then does removing it disable the feature.
        if currentTTSPreset.name == "ElevenLabs" {
            Settings.voiceoverEnabled = false
            voiceoverEnableBox.state = .off
        }
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
        KeyTester.testHeyGen(apiKey: key) { [weak self] result in
            guard let self = self else { return }
            self.heygenTestButton.isEnabled = true
            self.handle(result, on: self.heygenTestResult) {
                let saved = typed.isEmpty ? true : Keychain.set(typed, account: Keychain.heygenAPIKeyAccount)
                if saved {
                    self.heygenSavedBadge.isHidden = false
                    self.heygenRemoveButton.isHidden = false
                } else {
                    self.heygenTestResult.textColor = .systemOrange
                    self.heygenTestResult.stringValue = "✓ Valid, but couldn't save — allow Keychain access when prompted, then Test again."
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
                let saved = typed.isEmpty ? true : Keychain.set(typed, account: Keychain.sttAPIKeyAccount)
                guard saved else {
                    self.sttTestResult.textColor = .systemOrange
                    self.sttTestResult.stringValue = "✓ Valid, but couldn't save — allow Keychain access when prompted, then Test again."
                    return
                }
                self.verifiedSTT = true
                self.sttSavedBadge.isHidden = false
                self.sttRemoveButton.isHidden = false
                self.captionsEnableBox.state = .on
            }
        }
    }

    @objc private func testElevenKey() {
        let preset = currentTTSPreset
        let account = ttsKeyAccount
        let typed = elevenKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (Keychain.get(account: account) ?? "") : typed
        elevenTestButton.isEnabled = false
        elevenTestResult.textColor = .secondaryLabelColor
        elevenTestResult.stringValue = "Testing…"

        // On a passing test, persist a freshly-typed key (if any) and turn the feature on.
        let onOK: () -> Void = { [weak self] in
            guard let self = self else { return }
            if !typed.isEmpty {
                guard Keychain.set(typed, account: account) else {
                    self.elevenTestResult.textColor = .systemOrange
                    self.elevenTestResult.stringValue = "✓ Valid, but couldn't save — allow Keychain access when prompted, then Test again."
                    return
                }
                self.verifiedEleven = true
                self.elevenSavedBadge.isHidden = false
                self.elevenRemoveButton.isHidden = false
            }
            self.voiceoverEnableBox.state = .on
        }

        if preset.name == "ElevenLabs" {
            KeyTester.testElevenLabs(apiKey: key) { [weak self] result in
                guard let self = self else { return }
                self.elevenTestButton.isEnabled = true
                self.handle(result, on: self.elevenTestResult, onOK: onOK)
            }
        } else {
            let base = ttsBaseField.stringValue
            KeyTester.testTTSEndpoint(baseURL: base, apiKey: key,
                                      openAICompatible: preset.name == "OpenAI-compatible") { [weak self] result in
                guard let self = self else { return }
                self.elevenTestButton.isEnabled = true
                self.handle(result, on: self.elevenTestResult, onOK: onOK)
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
        commitEditing()   // flush any field that's still being edited, so a single click works
        Settings.aiProvider = providerPopup.selectedItem?.title ?? "OpenAI"
        Settings.sttBaseURL = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.sttModel = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.sttLanguage = langField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Voiceover / TTS provider selection.
        Settings.ttsProvider = ttsProviderPopup.selectedItem?.title ?? "ElevenLabs"
        Settings.ttsBaseURL = ttsBaseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.ttsModel = ttsModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.ttsVoice = ttsVoiceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // A typed value replaces the stored key; blank leaves it untouched (removal is explicit).
        var failed = false
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { failed = !Keychain.set(key, account: Keychain.sttAPIKeyAccount) || failed }
        // The Voiceover key routes to the account for the selected provider (ElevenLabs vs local/custom).
        let voKey = elevenKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !voKey.isEmpty { failed = !Keychain.set(voKey, account: ttsKeyAccount) || failed }
        let hgKey = heygenKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hgKey.isEmpty { failed = !Keychain.set(hgKey, account: Keychain.heygenAPIKeyAccount) || failed }

        // Enablement is explicit — persist exactly what the checkboxes show.
        Settings.captionsEnabled = (captionsEnableBox.state == .on)
        Settings.voiceoverEnabled = (voiceoverEnableBox.state == .on)

        if failed {
            status("Couldn't save a key to the Keychain — allow access when prompted, then Save again.", .systemOrange)
            return   // keep the window open so the user can retry
        }
        window?.close()
    }

    private func status(_ text: String, _ color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    /// Ends editing in any active text field so its value is committed before we read it.
    private func commitEditing() { window?.makeFirstResponder(nil) }

    @objc private func closeWindow() { commitEditing(); window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil }
}
