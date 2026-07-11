import AppKit

/// Lean voiceover panel: write or load a script, pick a voice, generate. The narration is
/// laid over the video from the start (you pace the recording to your script). Produces a
/// new `…voiceover.mp4`; the original is untouched.
@available(macOS 12.3, *)
final class VoiceoverController: NSObject, NSWindowDelegate {

    private let video: URL
    private let apiKey: String
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    private var textView: NSTextView!
    private var voicePopup: NSPopUpButton!
    private var generateButton: NSButton!
    private var statusLabel: NSTextField!
    private var voices: [Voiceover.Voice] = []

    init(video: URL, apiKey: String) {
        self.video = video
        self.apiKey = apiKey
    }

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let w: CGFloat = 560, h: CGFloat = 480
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Voiceover — \(video.deletingPathExtension().lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let header = NSTextField(wrappingLabelWithString:
            "Write or load the narration script, pick a voice, and Generate. The voice replaces "
            + "the audio from the start — pace your recording to the script.\n"
            + "Best for screen-only demos. If you're speaking on the webcam, your lips won't match "
            + "the new voice — use captions instead.")
        header.font = .systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 16, y: h - 66, width: w - 32, height: 48)
        content.addSubview(header)

        // Script editor.
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 150, width: w - 32, height: h - 150 - 78))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.string = Self.prefillScript(for: video)
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv

        let loadButton = NSButton(title: "Load Script…", target: self, action: #selector(loadScript))
        loadButton.bezelStyle = .rounded
        loadButton.frame = NSRect(x: 16, y: 112, width: 130, height: 28)
        content.addSubview(loadButton)

        let voiceLabel = NSTextField(labelWithString: "Voice")
        voiceLabel.font = .systemFont(ofSize: 12)
        voiceLabel.frame = NSRect(x: 16, y: 78, width: 60, height: 18)
        content.addSubview(voiceLabel)
        voicePopup = NSPopUpButton(frame: NSRect(x: 80, y: 74, width: 300, height: 26))
        voicePopup.addItem(withTitle: "Loading voices…")
        voicePopup.isEnabled = false
        content.addSubview(voicePopup)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 16, y: 18, width: 240, height: 18)
        content.addSubview(statusLabel)

        generateButton = NSButton(title: "Generate", target: self, action: #selector(generate))
        generateButton.bezelStyle = .rounded
        generateButton.keyEquivalent = "\r"
        generateButton.isEnabled = false
        generateButton.frame = NSRect(x: w - 126, y: 14, width: 110, height: 32)
        content.addSubview(generateButton)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: w - 226, y: 14, width: 100, height: 32)
        content.addSubview(close)

        window.contentView = content
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)

        loadVoices()
    }

    // MARK: - Voices

    private func loadVoices() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let list = try Voiceover().fetchVoices(apiKey: self.apiKey)
                DispatchQueue.main.async { self.populateVoices(list) }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "Couldn't load voices."
                    self.statusLabel.textColor = .systemRed
                    self.voicePopup.removeAllItems()
                    self.voicePopup.addItem(withTitle: "—")
                }
            }
        }
    }

    private func populateVoices(_ list: [Voiceover.Voice]) {
        voices = list
        voicePopup.removeAllItems()
        voicePopup.addItems(withTitles: list.map { $0.label })
        voicePopup.isEnabled = true
        // Restore last-used voice if still available.
        if let idx = list.firstIndex(where: { $0.id == Settings.elevenVoiceId }) {
            voicePopup.selectItem(at: idx)
        }
        generateButton.isEnabled = true
        statusLabel.stringValue = "\(list.count) voices"
        statusLabel.textColor = .secondaryLabelColor
    }

    // MARK: - Actions

    @objc private func loadScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        textView.string = text
    }

    @objc private func generate() {
        let script = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else {
            statusLabel.stringValue = "Write or load a script first."
            statusLabel.textColor = .systemOrange
            return
        }
        guard voicePopup.indexOfSelectedItem >= 0, voicePopup.indexOfSelectedItem < voices.count else {
            statusLabel.stringValue = "Pick a voice."
            statusLabel.textColor = .systemOrange
            return
        }
        let voice = voices[voicePopup.indexOfSelectedItem]
        Settings.elevenVoiceId = voice.id
        Settings.elevenVoiceName = voice.name

        generateButton.isEnabled = false
        generateButton.title = "Generating…"
        statusLabel.stringValue = "Synthesizing voice…"
        statusLabel.textColor = .secondaryLabelColor

        let video = self.video, key = self.apiKey, model = Settings.elevenModel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try Voiceover().generate(video: video, script: script,
                                                      voiceId: voice.id, model: model, apiKey: key)
                DispatchQueue.main.async {
                    // Keep the durable narration (…voiceover.narration.m4a) in place — a later
                    // avatar step reuses it. It is not deleted when this window closes.
                    self?.window?.close()
                    NSWorkspace.shared.activateFileViewerSelecting([result.videoURL])
                }
            } catch {
                DispatchQueue.main.async {
                    self?.generateButton.isEnabled = true
                    self?.generateButton.title = "Generate"
                    self?.statusLabel.stringValue = "Failed."
                    self?.statusLabel.textColor = .systemRed
                    let a = NSAlert()
                    a.messageText = "Voiceover failed"
                    a.informativeText = error.localizedDescription
                    a.runModal()
                }
            }
        }
    }

    @objc private func closeWindow() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        window = nil; onClose?(); onClose = nil
    }

    // MARK: - Prefill

    /// Pre-fills the script from an existing `.srt` sidecar (stripping timings), so a
    /// transcribed narration can be cleaned up and re-voiced. Empty if none exists.
    static func prefillScript(for video: URL) -> String {
        let srt = video.deletingPathExtension().appendingPathExtension("srt")
        guard let raw = try? String(contentsOf: srt, encoding: .utf8) else { return "" }
        let lines = raw.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            if t.contains("-->") { return false }
            if Int(t) != nil { return false }   // cue index
            return true
        }
        return lines.joined(separator: " ")
    }
}
