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
    private var languagePopup: NSPopUpButton!
    private var modeControl: NSSegmentedControl!
    private var summaryLabel: NSTextField!
    private var costLabel: NSTextField!
    private var languageRow: NSStackView!
    private var agentBox: NSView!
    private var agentBoxView: AgentHandoffBox!
    private var copyPromptButton: NSButton!
    private var actionButton: NSButton!
    private var costInlineLabel: NSTextField!
    private var scriptTabItem: NSTabViewItem!
    private var credits: Voiceover.Credits?
    /// Set after a generate, so the status line can report which lines didn't fit their scene.
    private var lastFitNote: String?

    /// What this window will do when Generate is pressed. Two genuinely different jobs, so the window
    /// asks which one rather than inferring it from whether a text field happens to be empty.
    private enum Mode: Int { case replace = 0, addLanguage = 1 }
    private var mode: Mode { Mode(rawValue: modeControl?.selectedSegment ?? 0) ?? .replace }
    private var selectedLanguage: NarrationLocalization.Language? {
        let i = languagePopup?.indexOfSelectedItem ?? -1
        return i >= 0 && i < NarrationLocalization.languages.count ? NarrationLocalization.languages[i] : nil
    }

    init(source: URL, apiKey: String) {
        self.apiKey = apiKey
        super.init(source: source)
    }

    override var actionTitle: String { "Voiceover" }
    override var nothingMessage: String { "Write or load a script first." }
    override var controlsFillWidth: Bool { true }

    // MARK: - Controls (script editor + voice picker)

    /// The window supplies its own action button, under the language picker.
    override var showsPrimaryButton: Bool { false }

    /// Names the artefact, not the mechanism. "Add French narration" describes a track being attached
    /// to a file; what the user is actually getting is another DemoTape, in French.
    override var generateTitle: String {
        guard mode == .addLanguage else { return "Re-record the narration" }
        return selectedLanguage.map { "Generate new DemoTape in \($0.name)" } ?? "Generate in another language"
    }

    @objc private func inlineGenerate() { beginGenerate() }

    override func setBusy(_ busy: Bool) {
        super.setBusy(busy)
        actionButton?.isEnabled = !busy
        copyPromptButton?.isEnabled = !busy
    }

    override func makeControls() -> NSView {
        // What this demo already is. A narration you're about to change is not a blank slate — the
        // useful first sentence is "this is what you have", not "type something here".
        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        costLabel = NSTextField(labelWithString: "")
        costLabel.font = .systemFont(ofSize: 11)
        costLabel.textColor = .secondaryLabelColor
        costLabel.alignment = .right
        costLabel.lineBreakMode = .byTruncatingHead
        let headerRow = NSStackView(views: [summaryLabel, NSView(), costLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 12

        modeControl = NSSegmentedControl(labels: ["Replace the narrator", "Add a language"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged))
        modeControl.selectedSegment = 0
        modeControl.segmentDistribution = .fillEqually

        let form = makeVoiceForm()
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let narrationItem = NSTabViewItem(identifier: "narration")
        narrationItem.label = "Narration"
        narrationItem.view = form
        scriptTabItem = NSTabViewItem(identifier: "script")
        scriptTabItem.label = "Script"
        scriptTabItem.view = makeScriptEditor()
        tabs.addTabViewItem(narrationItem)
        tabs.addTabViewItem(scriptTabItem)
        tabs.heightAnchor.constraint(equalToConstant: 232).isActive = true

        let stack = NSStackView(views: [headerRow, modeControl, tabs])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        [headerRow, modeControl, tabs].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            $0.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        updateForMode()
        return stack
    }

    /// The Narration tab: voice, language, and the option of handing the translation to an agent.
    private func makeVoiceForm() -> NSView {
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

        let voiceRow = NSStackView(views: [voiceLabel, voicePopup, previewVoiceButton, NSView()])
        voiceRow.orientation = .horizontal
        voiceRow.spacing = 10

        // Language row — a list, not a text field. The tag becomes the filename (…voiceover.es.mp4),
        // so typing it freehand invited a mislabelled file for no benefit.
        let languageLabel = NSTextField(labelWithString: "Language")
        languageLabel.font = .systemFont(ofSize: 13)
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: NarrationLocalization.languages.map(NarrationLocalization.label))
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languageRow = NSStackView(views: [languageLabel, languagePopup, NSView()])
        languageRow.orientation = .horizontal
        languageRow.spacing = 10

        // The action sits with the choice that decides it, right under the language — not stranded at
        // the bottom of the window where it reads as unrelated to anything above it.
        actionButton = NSButton(title: generateTitle, target: self, action: #selector(inlineGenerate))
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.keyEquivalent = "\r"
        Theme.stylePrimary(actionButton)
        costInlineLabel = NSTextField(labelWithString: "")
        costInlineLabel.font = .systemFont(ofSize: 11)
        costInlineLabel.textColor = .secondaryLabelColor
        let actionRow = NSStackView(views: [actionButton, costInlineLabel, NSView()])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .centerY

        agentBox = makeAgentHandoff()

        let form = NSStackView(views: [voiceRow, languageRow, actionRow, agentBox])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 14
        form.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 14, right: 14)
        [voiceRow, languageRow, actionRow, agentBox].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 14).isActive = true
            $0.trailingAnchor.constraint(equalTo: form.trailingAnchor, constant: -14).isActive = true
        }
        return form
    }

    /// Translating well is a judgement call, not a lookup — so the window offers to hand the job to
    /// the user's own coding agent instead of pretending a button can do it. The prompt names the
    /// files, the command, and the fit rule the agent has to iterate against.
    private func makeAgentHandoff() -> NSView {
        let box = AgentHandoffBox(
            headline: "",
            detail: "It reads this demo's script, writes the translation, and checks every line still "
                  + "fits its scene — then makes the new DemoTape beside this one.",
            target: self, action: #selector(copyAgentPrompt))
        agentBoxView = box
        copyPromptButton = box.button
        return box
    }

    /// The Script tab: the words themselves, out of the way of the everyday choices. A scene-synced
    /// demo shows each line with the moment it belongs to, which is what makes hand-editing possible.
    private func makeScriptEditor() -> NSView {
        let fromCaptions = NSButton(title: "Load from captions", target: self, action: #selector(loadFromCaptions))
        fromCaptions.bezelStyle = .rounded
        let loadButton = NSButton(title: "Load Script…", target: self, action: #selector(loadScript))
        loadButton.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.stringValue = "A time in brackets keeps each line on its own moment."
        let toolRow = NSStackView(views: [hint, NSView(), fromCaptions, loadButton])
        toolRow.orientation = .horizontal
        toolRow.spacing = 10

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

        let stack = NSStackView(views: [toolRow, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        toolRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            toolRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14)
        ])
        return stack
    }

    // MARK: - Mode, language, and the numbers that matter

    @objc private func modeChanged() { updateForMode() }
    @objc private func languageChanged() { updateForMode() }

    /// Keeps the window honest about what pressing Generate will do.
    private func updateForMode() {
        let adding = mode == .addLanguage
        languageRow?.isHidden = !adding
        agentBox?.isHidden = !adding
        refreshGenerateTitle()
        actionButton?.title = generateTitle
        if let language = selectedLanguage {
            agentBoxView?.headline = "Or let your coding agent make the \(language.name) one"
        }
        costInlineLabel?.stringValue = runCost
        refreshSummary()
        setStatus(modeHint, isError: false)
    }

    /// The lines this run will speak. A timed script is per scene; plain prose is one block.
    private var linesToSpeak: [Voiceover.TimedLine] {
        let timed = Voiceover.parseTimedScript(scriptView?.string ?? "")
        if !timed.isEmpty { return timed }
        return [Voiceover.TimedLine(at: 0, say: scriptView?.string ?? "")]
    }

    /// What pressing the button costs, next to the button. Speech is billed per character, so this is
    /// knowable before spending anything — and much more useful before than after.
    private var runCost: String {
        let chars = NarrationLocalization.characterCount(of: linesToSpeak)
        guard chars > 0 else { return "" }
        return NarrationLocalization.costSummary(characters: chars, remaining: credits?.remaining)
    }

    private var modeHint: String {
        if mode == .addLanguage {
            let name = selectedLanguage?.name ?? "another language"
            return "Keeps this DemoTape as it is and makes a \(name) one beside it, on the same timings."
        }
        return "Speaks the script again on this file, keeping the picture."
    }

    /// "14 scenes · narrated in English by Matilda · also in Español"
    private func refreshSummary() {
        guard summaryLabel != nil else { return }
        var parts: [String] = []
        let timed = Voiceover.savedTimedScript(besideVideo: source) ?? []
        if timed.count > 1 { parts.append("\(timed.count) scenes") }
        let voiceName = savedVoiceName ?? (voices.isEmpty ? nil : voices[max(0, voicePopup.indexOfSelectedItem)].name)
        parts.append(voiceName.map { "narrated by \($0)" } ?? "no narration yet")
        let tags = Voiceover.existingTags(besideVideo: source)
        if !tags.isEmpty {
            let named = tags.map { NarrationLocalization.language(forCode: $0).map(\.endonym) ?? $0 }
            parts.append("also in \(named.joined(separator: ", "))")
        }
        summaryLabel.stringValue = parts.joined(separator: " · ")
        costLabel.stringValue = credits.map { "\($0.summary)" } ?? ""
    }

    /// The voice the recording was narrated with, when the driver saved it.
    private var savedVoiceName: String? {
        guard let id = savedVoiceId else { return nil }
        return voices.first { $0.id == id }?.name
    }

    /// Puts the hand-off prompt on the clipboard, ready to paste into a coding agent.
    @objc private func copyAgentPrompt() {
        // Never return without writing the clipboard: leaving the previous copy in place reads as the
        // app handing out the wrong prompt, and the user has no way to tell the difference.
        guard let language = selectedLanguage else {
            setStatus("Pick a language first.", isError: true)
            return
        }
        let dir = source.deletingLastPathComponent().path
        let prompt = NarrationLocalization.agentPrompt(recordingDir: dir, language: language)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        setStatus("Copied the \(language.name) prompt — paste it into your coding agent.", isError: false)
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
        refreshSummary()
        setStatus("Using \(Settings.ttsProvider) at \(Settings.ttsBaseURL). \(modeHint)", isError: false)
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
        self.credits = credits
        voicePopup.removeAllItems()
        voicePopup.addItems(withTitles: list.map { $0.label })
        voicePopup.isEnabled = true
        // Prefer the voice this demo was actually narrated with, so "replace the narrator" starts from
        // the current one rather than whatever was last used somewhere else.
        let savedId = savedVoiceId
        if let idx = list.firstIndex(where: { $0.id == savedId })
            ?? list.firstIndex(where: { $0.id == Settings.elevenVoiceId }) {
            voicePopup.selectItem(at: idx)
        }
        previewVoiceButton.isEnabled = true
        refreshSummary()
        // The balance lives in the header; the status line only speaks up when it's a problem.
        if let c = credits, c.remaining == 0 {
            setStatus("Out of credits — add some at elevenlabs.io before generating.", isError: true)
        } else if let c = credits, c.remaining < 500 {
            setStatus("Low balance (\(c.summary)). \(modeHint)", isError: true)
        } else {
            setStatus(modeHint, isError: false)
        }
    }

    /// The voice id saved beside the recording by the driver, if any.
    private var savedVoiceId: String? {
        let url = source.deletingLastPathComponent().appendingPathComponent("timeline.json")
        struct Timeline: Decodable { let voiceId: String? }
        guard let data = try? Data(contentsOf: url),
              let id = (try? JSONDecoder().decode(Timeline.self, from: data))?.voiceId,
              !id.isEmpty else { return nil }
        return id
    }

    /// What this window is about to do, in one sentence — different for a scene-synced demo, where
    /// the interesting job is usually adding a second language to a narration that already works.
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
        let script = Self.captionsScript(for: source)
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
        updateForMode()
    }

    // MARK: - Generate (final voiceover file)

    override func render(progress: @escaping (Double) -> Void) throws -> URL? {
        let script = scriptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return nil }

        // Replacing writes the plain …voiceover.mp4; adding a language writes …voiceover.<code>.mp4 and
        // leaves the original playable.
        let tag = mode == .addLanguage ? (selectedLanguage?.code ?? "") : ""

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
        // A timed script (lines prefixed with their offsets) is spoken scene by scene, each line laid
        // at its own moment. That's what keeps a translation glued to the picture — the words change,
        // the timing doesn't. Plain prose is still spoken as one block from the start.
        lastFitNote = nil
        let timed = Voiceover.parseTimedScript(script)
        if timed.count > 1 {
            let result = try Voiceover().generateTimeline(video: source, lines: timed, config: config,
                                                          tag: tag.isEmpty ? nil : tag,
                                                          progress: { progress($0 * 0.9) })
            let long = result.fit.filter { $0.overrun > 0.25 }
            if !long.isEmpty {
                let worst = long.max(by: { $0.overrun < $1.overrun })!
                lastFitNote = "\(long.count) line(s) run longer than their scene "
                    + String(format: "(worst: line %d by %.1fs)", worst.index + 1, worst.overrun)
                    + " — the lines after them are pushed later. Shorten them and generate again."
            }
            return result.video
        }
        return try Voiceover().generate(video: source, script: script, config: config,
                                        tag: tag.isEmpty ? nil : tag).videoURL
    }

    /// After a successful generate, say plainly if any line didn't fit — the failure mode of a
    /// translated narration is drift, and it is invisible unless someone says so.
    override func renderDidFinish(output: URL) {
        if let note = lastFitNote {
            setStatus("Wrote \(output.lastPathComponent). \(note)", isError: true)
        } else {
            let tags = Voiceover.existingTags(besideVideo: source)
            let also = tags.isEmpty ? "" : " Versions beside it: \(tags.joined(separator: ", "))."
            setStatus("Wrote \(output.lastPathComponent).\(also)", isError: false)
        }
    }

    // MARK: - Prefill

    /// Pre-fills the script, preferring the demo's OWN scene script when the recording has one.
    ///
    /// This is what makes "add another language" a five-minute job: the lines that were spoken, with
    /// the moment each belongs to, ready to be translated in place. Captions are the fallback for a
    /// recording that wasn't driven scene by scene.
    static func prefillScript(for video: URL) -> String {
        if let timed = Voiceover.savedTimedScript(besideVideo: video), timed.count > 1 {
            return Voiceover.formatTimedScript(timed)
        }
        return captionsScript(for: video)
    }

    /// Pre-fills the script from an existing `.srt` sidecar (stripping timings), so a transcribed
    /// narration can be cleaned up and re-voiced. Empty if none exists.
    static func captionsScript(for video: URL) -> String {
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
