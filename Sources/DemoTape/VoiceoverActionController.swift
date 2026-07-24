import AppKit
import AVFoundation

/// Focused "Voiceover" action. Write or load a script, audition and pick an ElevenLabs voice,
/// and Generate preview lays the narration over the video — producing a final `…voiceover.mp4`.
/// The durable `…voiceover.narration.m4a` sidecar is kept so a later avatar step can reuse it.
@available(macOS 12.3, *)
final class VoiceoverActionController: ActionPreviewController {

    private let apiKey: String
    private var voices: [Voiceover.Voice] = []
    private var previewPlayer: AVPlayer?

    private var scriptView: NSTextView!
    private var voicePopup: NSPopUpButton!
    private var previewVoiceButton: NSButton!

    init(source: URL, apiKey: String) {
        self.apiKey = apiKey
        super.init(source: source)
    }

    override var actionTitle: String { "Voiceover" }
    override var nothingMessage: String { "Write or load a script first." }
    override var controlsFillWidth: Bool { true }

    // MARK: - Controls (script editor + voice picker)

    override func makeControls() -> NSView {
        // Voice row.
        let voiceLabel = NSTextField(labelWithString: "Voice")
        voiceLabel.font = .systemFont(ofSize: 13)
        voicePopup = NSPopUpButton()
        voicePopup.addItem(withTitle: "Loading voices…")
        voicePopup.isEnabled = false

        previewVoiceButton = NSButton(image: NSImage(systemSymbolName: "play.circle",
                                                     accessibilityDescription: "Preview voice") ?? NSImage(),
                                      target: self, action: #selector(previewVoice))
        previewVoiceButton.bezelStyle = .rounded
        previewVoiceButton.toolTip = "Hear a sample of this voice"
        previewVoiceButton.isEnabled = false

        let fromCaptions = NSButton(title: "Load from captions", target: self, action: #selector(loadFromCaptions))
        fromCaptions.bezelStyle = .rounded
        let loadButton = NSButton(title: "Load Script…", target: self, action: #selector(loadScript))
        loadButton.bezelStyle = .rounded
        let voiceRow = NSStackView(views: [voiceLabel, voicePopup, previewVoiceButton, NSView(),
                                           fromCaptions, loadButton])
        voiceRow.orientation = .horizontal
        voiceRow.spacing = 10

        // Script editor.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.autoresizingMask = [.width]
        tv.string = Self.prefillScript(for: source)
        scroll.documentView = tv
        scriptView = tv

        let stack = NSStackView(views: [voiceRow, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        voiceRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            voiceRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            voiceRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        return stack
    }

    // MARK: - Lifecycle

    private var ttsProvider: Voiceover.TTSProvider { Voiceover.TTSProvider(name: Settings.ttsProvider) }

    override func windowDidAppear() {
        if ttsProvider == .elevenLabs {
            setStatus("Loading voices…", isError: false)
            loadVoices()
        } else {
            configureForLocalProvider()
        }
    }

    /// Non-ElevenLabs providers have no live voice list — the voice is a name configured in AI
    /// Settings. Show it in the popup and skip all network calls so generation works offline.
    private func configureForLocalProvider() {
        let voice = Settings.ttsVoice.isEmpty ? "default" : Settings.ttsVoice
        voicePopup.removeAllItems()
        voicePopup.addItem(withTitle: "Server voice: \(voice)")
        voicePopup.isEnabled = false
        previewVoiceButton.isEnabled = false
        setStatus("Using \(Settings.ttsProvider) at \(Settings.ttsBaseURL). Write your script, then Generate preview.",
                  isError: false)
    }

    private func loadVoices() {
        let key = apiKey
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let list = try Voiceover().fetchVoices(apiKey: key)
                let credits = try? Voiceover().fetchCredits(apiKey: key)   // best-effort heads-up
                DispatchQueue.main.async { self?.populateVoices(list, credits: credits) }
            } catch {
                DispatchQueue.main.async {
                    self?.voicePopup.removeAllItems()
                    self?.voicePopup.addItem(withTitle: "—")
                    self?.setStatus("Couldn't load voices: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func populateVoices(_ list: [Voiceover.Voice], credits: Voiceover.Credits? = nil) {
        voices = list
        voicePopup.removeAllItems()
        voicePopup.addItems(withTitles: list.map { $0.label })
        voicePopup.isEnabled = true
        if let idx = list.firstIndex(where: { $0.id == Settings.elevenVoiceId }) {
            voicePopup.selectItem(at: idx)
        }
        previewVoiceButton.isEnabled = true
        // Proactively flag an empty/low balance so the user tops up before hitting a wall mid-generate.
        if let c = credits, c.remaining == 0 {
            setStatus("ElevenLabs is out of credits (0 left) — add credits at elevenlabs.io before generating.",
                      isError: true)
        } else if let c = credits, c.remaining < 500 {
            setStatus("Heads up: ElevenLabs is low (\(c.summary)). Top up at elevenlabs.io if you run out.",
                      isError: true)
        } else {
            let bal = credits.map { " · \($0.summary)" } ?? ""
            setStatus("\(list.count) voices\(bal). Audition with ▶, write your script, then Generate preview.",
                      isError: false)
        }
    }

    // MARK: - Actions

    /// Plays the selected voice's sample clip (free — no synthesis, no credits).
    @objc private func previewVoice() {
        guard voicePopup.indexOfSelectedItem >= 0, voicePopup.indexOfSelectedItem < voices.count else { return }
        let voice = voices[voicePopup.indexOfSelectedItem]
        guard let url = URL(string: voice.previewURL), !voice.previewURL.isEmpty else {
            setStatus("No sample available for “\(voice.name)”.", isError: false)
            return
        }
        previewPlayer = AVPlayer(url: url)
        previewPlayer?.play()
        setStatus("Playing a sample of “\(voice.name)”.", isError: false)
    }

    @objc private func loadScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        scriptView.string = text
    }

    /// Pulls the script from the current file's captions/transcript on demand.
    @objc private func loadFromCaptions() {
        let script = Self.prefillScript(for: source)
        guard !script.isEmpty else {
            setStatus("No captions found for this file — generate captions first, or type a script.",
                      isError: false)
            return
        }
        scriptView.string = script
        setStatus("Loaded the script from this file's captions.", isError: false)
    }

    /// When the user switches files, refresh the script from the new file's captions if the
    /// editor is empty (don't clobber a script they've written).
    override func sourceDidChange() {
        guard scriptView != nil, scriptView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        scriptView.string = Self.prefillScript(for: source)
    }

    // MARK: - Generate (final voiceover file)

    override func render(progress: @escaping (Double) -> Void) throws -> URL? {
        let script = scriptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return nil }

        let config: Voiceover.TTSConfig
        if ttsProvider == .elevenLabs {
            guard voicePopup.indexOfSelectedItem >= 0, voicePopup.indexOfSelectedItem < voices.count else {
                throw SimpleError("Pick a voice first.")
            }
            let voice = voices[voicePopup.indexOfSelectedItem]
            Settings.elevenVoiceId = voice.id
            Settings.elevenVoiceName = voice.name
            Settings.elevenVoiceGender = voice.gender   // lets the avatar step auto-match gender
            config = Voiceover.TTSConfig(provider: .elevenLabs, model: Settings.elevenModel,
                                         voice: voice.id, apiKey: apiKey)
        } else {
            // Local/custom: read endpoint + voice from Settings; key (if any) from the TTS account.
            let key = Keychain.get(account: Keychain.ttsAPIKeyAccount) ?? ""
            config = Voiceover.TTSConfig(provider: ttsProvider, baseURL: Settings.ttsBaseURL,
                                         model: Settings.ttsModel, voice: Settings.ttsVoice, apiKey: key)
        }
        return try Voiceover().generate(video: source, script: script, config: config).videoURL
    }

    // MARK: - Prefill

    /// Pre-fills the script from an existing `.srt` sidecar (stripping timings), so a transcribed
    /// narration can be cleaned up and re-voiced. Empty if none exists.
    static func prefillScript(for video: URL) -> String {
        let candidates = [SourcePaths(source: video).srtURL,
                          video.deletingPathExtension().appendingPathExtension("srt")]   // legacy fallback
        guard let raw = candidates.lazy.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first else {
            return ""
        }
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

/// A lightweight error carrying a user-facing message.
struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
