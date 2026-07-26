import AppKit

/// Focused "Captions" action. On open it transcribes the source (reusing a cached transcript so
/// it never re-charges), shows the timed, editable lines in a full-width tab under the video, and
/// lets you pick the language. Generate preview burns the current lines into a final video.
@available(macOS 12.3, *)
final class CaptionsActionController: ActionPreviewController, NSTextFieldDelegate {

    private var config: Captions.Config
    private var cues: [CaptionCue]
    private let hadCache: Bool

    private var languagePopup: NSPopUpButton!
    private var targetLanguagePopup: NSPopUpButton!
    private var transcriptLabel: NSTextField!
    private var transcribeButton: NSButton!
    private var copyPromptButton: NSButton!
    private var agentBox: NSView!
    private var subtitlesDocStack: NSStackView!
    private var cueFields: [NSTextField] = []
    private var updateButton: NSButton!
    /// The text each row started with, so "has anything changed?" is answerable rather than assumed.
    private var originalTexts: [String] = []

    /// The window is taller than the default: a header, tabs, and the agent hand-off don't fit in 800pt,
    /// and what got pushed off the bottom was the Generate button and the status line.
    override var preferredContentSize: NSSize { NSSize(width: 900, height: 940) }

    // Selected caption look (persisted). Cards in the Design tab set this.
    private static let styleDefaultsKey = "captionStyleID"
    private var selectedStyle: CaptionStyle = {
        let id = UserDefaults.standard.string(forKey: CaptionsActionController.styleDefaultsKey) ?? "pop"
        return CaptionStyle.byID(id)
    }()
    private var styleCards: [CaptionStyleCard] = []

    // (label, ISO-639-1 hint). Empty = auto-detect.
    private let languages: [(String, String)] = [
        ("Auto-detect", ""), ("English", "en"), ("Spanish", "es"), ("French", "fr"),
        ("German", "de"), ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"),
        ("Japanese", "ja"), ("Chinese", "zh"), ("Hindi", "hi"), ("Arabic", "ar")
    ]

    init(source: URL, cachedCues: [CaptionCue]?, config: Captions.Config) {
        self.config = config
        self.cues = cachedCues ?? []
        self.hadCache = !(cachedCues?.isEmpty ?? true)
        super.init(source: source)
    }

    override var actionTitle: String { "Captions" }
    override var nothingMessage: String { "No transcript yet — transcribe first." }
    override var controlsFillWidth: Bool { true }

    // MARK: - Controls (full-width tab: Language + timed, editable Subtitles)

    override func makeControls() -> NSView {
        let header = makeHeaderRow()

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.heightAnchor.constraint(equalToConstant: 214).isActive = true
        // Design first: choosing the look is the common job, and it's what people came here to do.
        // Editing the transcript line by line is the exception, so it sits behind it.
        tabView.addTabViewItem(makeDesignTab())
        tabView.addTabViewItem(makeSubtitlesTab())

        agentBox = makeAgentHandoff()

        let stack = NSStackView(views: [header, tabView, agentBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        [header, tabView, agentBox].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            $0.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        refreshHeader()
        return stack
    }

    /// What this window is working on, and the one setting that changes the transcript. Both were
    /// hidden — the language sat in a tab nobody opens, and the transcript's state was only visible as
    /// an error after pressing Generate.
    private func makeHeaderRow() -> NSView {
        transcriptLabel = NSTextField(labelWithString: "")
        transcriptLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let spokenLabel = NSTextField(labelWithString: "Spoken")
        spokenLabel.font = .systemFont(ofSize: 13)
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: languages.map { $0.0 })
        // The file usually says what it is (…voiceover.fr.mp4). Preselect that rather than making the
        // user tell the app something it can already read off the name.
        let fileLanguage = NarrationLocalization.languageOfFile(source)
        let wanted = config.language.isEmpty ? (fileLanguage?.code ?? "") : config.language
        if let idx = languages.firstIndex(where: { $0.1 == wanted }) {
            languagePopup.selectItem(at: idx)
            config.language = wanted
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.isEnabled = !config.apiKey.isEmpty

        transcribeButton = NSButton(title: "Transcribe", target: self, action: #selector(transcribeTapped))
        transcribeButton.bezelStyle = .rounded

        let row = NSStackView(views: [transcriptLabel, NSView(), spokenLabel, languagePopup, transcribeButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    /// Captions in a language the audio isn't in is a translation, which the app doesn't do — so it
    /// hands the job over with everything needed to finish it, rather than offering a button that
    /// would quietly produce the wrong thing.
    private func makeAgentHandoff() -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = .quaternaryLabelColor.withAlphaComponent(0.08)
        box.borderColor = .separatorColor
        box.cornerRadius = 8
        box.borderWidth = 1
        box.titlePosition = .noTitle

        let title = NSTextField(labelWithString: "Or copy this prompt and let your AI assistant write them in")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        targetLanguagePopup = NSPopUpButton()
        targetLanguagePopup.addItems(withTitles: NarrationLocalization.languages.map(NarrationLocalization.label))
        targetLanguagePopup.target = self
        targetLanguagePopup.action = #selector(targetLanguageChanged)
        if let spoken = NarrationLocalization.languageOfFile(source),
           let idx = NarrationLocalization.languages.firstIndex(where: { $0.code == spoken.code }) {
            targetLanguagePopup.selectItem(at: idx)
        }
        let titleRow = NSStackView(views: [title, targetLanguagePopup, NSView()])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8

        let blurb = NSTextField(wrappingLabelWithString:
            "It translates every line without touching a single timing, keeps them short enough to read, "
            + "and burns the result beside this video.")
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        copyPromptButton = NSButton(title: "Copy prompt", target: self, action: #selector(copyCaptionPrompt))
        copyPromptButton.bezelStyle = .rounded
        let row = NSStackView(views: [blurb, copyPromptButton])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY

        let stack = NSStackView(views: [titleRow, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12)
        ])
        return box
    }

    private var selectedTargetLanguage: NarrationLocalization.Language? {
        let i = targetLanguagePopup?.indexOfSelectedItem ?? -1
        return i >= 0 && i < NarrationLocalization.languages.count ? NarrationLocalization.languages[i] : nil
    }

    @objc private func targetLanguageChanged() { refreshHeader() }

    /// Says where the transcript stands, in words, at the top of the window.
    private func refreshHeader() {
        guard transcriptLabel != nil else { return }
        let spoken = NarrationLocalization.languageOfFile(source)?.name
        let subject = spoken.map { "\($0) audio" } ?? "this video"
        transcriptLabel.stringValue = cues.isEmpty
            ? "No subtitles yet for \(subject)"
            : "\(cues.count) subtitle lines from \(subject)"
        transcribeButton?.title = cues.isEmpty ? "Transcribe" : "Transcribe again"
        if let target = selectedTargetLanguage, let spokenName = spoken, target.name != spokenName {
            copyPromptButton?.toolTip = "Translate the \(spokenName) subtitles into \(target.name)"
        }
    }

    /// Puts the caption-translation prompt on the clipboard.
    @objc private func copyCaptionPrompt() {
        guard let target = selectedTargetLanguage else { return }
        // Write the current lines out so the prompt points at a file that matches what's on screen.
        let paths = SourcePaths(source: source)
        if !cues.isEmpty {
            paths.ensureSourceDir()
            try? Captions.writeSRT(cues, to: paths.srtURL)
        }
        // No transcript is not a dead end: the prompt gains a transcribe step. Refusing to copy left
        // whatever was on the clipboard BEFORE — which looked exactly like the app handing out the
        // wrong prompt, because the previous copy (a narration prompt, in another language) is what
        // then got pasted.
        let hasTranscript = FileManager.default.fileExists(atPath: paths.srtURL.path)
        let prompt = NarrationLocalization.captionAgentPrompt(
            video: source, srtPath: paths.srtURL.path, language: target,
            spokenLanguage: NarrationLocalization.languageOfFile(source),
            hasTranscript: hasTranscript)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        setStatus(hasTranscript
                  ? "Copied the \(target.name) subtitle prompt — paste it into your AI assistant."
                  : "Copied the \(target.name) subtitle prompt. There's no transcript yet, so it starts "
                    + "by transcribing this video.",
                  isError: false)
    }

    // MARK: - Design tab (style preview cards)

    private func makeDesignTab() -> NSTabViewItem {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        grid.translatesAutoresizingMaskIntoConstraints = false

        styleCards.removeAll()
        let perRow = 4
        var row: NSStackView? = nil
        for (i, style) in CaptionStyle.all.enumerated() {
            if i % perRow == 0 {
                let r = NSStackView()
                r.orientation = .horizontal
                r.spacing = 10
                r.alignment = .top
                grid.addArrangedSubview(r)
                row = r
            }
            let card = CaptionStyleCard(style: style) { [weak self] chosen in
                self?.selectStyle(chosen)
            }
            card.isSelected = (style.id == selectedStyle.id)
            styleCards.append(card)
            row?.addArrangedSubview(card)
        }

        scroll.documentView = grid
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
        ])

        let tab = NSTabViewItem(identifier: "design")
        tab.label = "Design"
        tab.view = scroll
        return tab
    }

    private func selectStyle(_ style: CaptionStyle) {
        selectedStyle = style
        UserDefaults.standard.set(style.id, forKey: CaptionsActionController.styleDefaultsKey)
        for card in styleCards { card.isSelected = (card.styleID == style.id) }
        setStatus("Style: \(style.name)\(style.animated ? " (animated)" : ""). Generate preview to apply.",
                  isError: false)
    }

    private func makeSubtitlesTab() -> NSTabViewItem {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        subtitlesDocStack = NSStackView()
        subtitlesDocStack.orientation = .vertical
        subtitlesDocStack.alignment = .leading
        subtitlesDocStack.spacing = 6
        subtitlesDocStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        subtitlesDocStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = subtitlesDocStack
        NSLayoutConstraint.activate([
            subtitlesDocStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            subtitlesDocStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            subtitlesDocStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor)
        ])

        updateButton = NSButton(title: "Update subtitles", target: self, action: #selector(updateSubtitles))
        updateButton.bezelStyle = .rounded
        updateButton.isEnabled = false      // nothing edited yet, so nothing to update

        let container = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        container.addSubview(updateButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: updateButton.topAnchor, constant: -8),
            updateButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            updateButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        let tab = NSTabViewItem(identifier: "subtitles")
        tab.label = "Subtitles"
        tab.view = container
        return tab
    }

    /// Rebuilds the timed, editable rows from `cues`.
    private func rebuildSubtitleRows() {
        guard let doc = subtitlesDocStack else { return }
        doc.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cueFields.removeAll()
        originalTexts = cues.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
        for cue in cues {
            let time = NSTextField(labelWithString: timecode(cue.start))
            time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            time.textColor = .secondaryLabelColor
            time.alignment = .right
            time.translatesAutoresizingMaskIntoConstraints = false
            time.widthAnchor.constraint(equalToConstant: 56).isActive = true

            let field = NSTextField(string: cue.text.replacingOccurrences(of: "\n", with: " "))
            field.font = .systemFont(ofSize: 12)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.delegate = self          // so the Update button can react to an edit
            cueFields.append(field)

            let row = NSStackView(views: [time, field])
            row.orientation = .horizontal
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            doc.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -16).isActive = true
        }
        refreshUpdateButton()
    }

    /// How many rows differ from what was transcribed.
    private var editedLineCount: Int {
        zip(cueFields, originalTexts).reduce(0) { count, pair in
            count + (pair.0.stringValue.trimmingCharacters(in: .whitespaces)
                     == pair.1.trimmingCharacters(in: .whitespaces) ? 0 : 1)
        }
    }

    /// The button says whether there is anything to do. A permanently-enabled "Update subtitles" gives
    /// no signal that an edit was even registered, let alone that it still needs saving.
    private func refreshUpdateButton() {
        guard updateButton != nil else { return }
        let edited = editedLineCount
        updateButton.isEnabled = edited > 0
        updateButton.title = edited == 0
            ? "Update subtitles"
            : (edited == 1 ? "Update 1 edited line" : "Update \(edited) edited lines")
    }

    // MARK: - Lifecycle

    override func windowDidAppear() {
        refreshHeader()
        if hadCache {
            rebuildSubtitleRows()
            setStatus("Loaded transcript. Edit the Subtitles tab, then Generate preview.", isError: false)
        } else if !config.apiKey.isEmpty {
            transcribe()
        } else {
            setStatus("Add your captions key in AI Settings to transcribe.", isError: true)
        }
    }

    // MARK: - Transcription

    @objc private func languageChanged() {
        config.language = languages[max(0, languagePopup.indexOfSelectedItem)].1
        transcribe()
    }

    @objc private func transcribeTapped() { transcribe() }

    private func transcribe() {
        guard !config.apiKey.isEmpty else {
            setStatus("Add your captions key in AI Settings to transcribe.", isError: true)
            return
        }
        setBusy(true)
        setStatus("Transcribing…", isError: false)
        let cfg = config
        let source = self.source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try Captions().generate(for: source, config: cfg)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setBusy(false)
                    self.cues = result.cues
                    self.rebuildSubtitleRows()
                    self.refreshHeader()
                    self.setStatus("Transcribed \(result.cues.count) lines. Edit if needed, then Generate preview.",
                                   isError: false)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setBusy(false)
                    self?.setStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    // MARK: - Manual edits

    /// Reads the edited text fields back onto the original cue timings (row N → cue N).
    private func applyEdits() {
        for (i, field) in cueFields.enumerated() where i < cues.count {
            cues[i].text = field.stringValue.trimmingCharacters(in: .whitespaces)
        }
        cues.removeAll { $0.text.isEmpty }
    }

    /// Live edit tracking — the Update button reflects the state of the text as it's typed.
    func controlTextDidChange(_ obj: Notification) { refreshUpdateButton() }

    @objc private func updateSubtitles() {
        let edited = editedLineCount
        applyEdits()
        Captions.saveTranscript(cues, for: source)
        let paths = SourcePaths(source: source)
        paths.ensureSourceDir()
        try? Captions.writeSRT(cues, to: paths.srtURL)
        try? Captions.writeVTT(cues, to: paths.vttURL)
        rebuildSubtitleRows()
        refreshHeader()
        setStatus("Saved \(edited) edited line\(edited == 1 ? "" : "s"). Generate preview to burn them in.",
                  isError: false)
    }

    // MARK: - Burn (Generate preview → final file)

    override func render(progress: @escaping (Double) -> Void) throws -> URL? {
        applyEdits()
        guard !cues.isEmpty else { return nil }
        Captions.saveTranscript(cues, for: source)
        let out = SourcePaths(source: source).output(suffix: "captioned")
        try CaptionBurner().burn(video: source, cues: cues, style: selectedStyle, to: out)
        return out
    }

    private func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A clickable preview card for one `CaptionStyle`: the static alpha preview rendered on a dark
/// tile, with the style name and an "Animated" badge. Selection shows an accent border.
@available(macOS 12.3, *)
final class CaptionStyleCard: NSView {

    let styleID: String
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    private let onSelect: (CaptionStyle) -> Void
    private let style: CaptionStyle

    private let tileSize = CGSize(width: 150, height: 78)

    init(style: CaptionStyle, onSelect: @escaping (CaptionStyle) -> Void) {
        self.style = style
        self.styleID = style.id
        self.onSelect = onSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let imageView = NSImageView()
        imageView.image = style.previewImage(size: tileSize)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: style.name)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.alignment = .center

        let badge = NSTextField(labelWithString: style.animated ? "Animated" : "Static")
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.textColor = style.animated ? .systemOrange : .secondaryLabelColor
        badge.alignment = .center

        let stack = NSStackView(views: [imageView, title, badge])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: tileSize.width),
            imageView.heightAnchor.constraint(equalToConstant: tileSize.height),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2.5
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { onSelect(style) }
}
