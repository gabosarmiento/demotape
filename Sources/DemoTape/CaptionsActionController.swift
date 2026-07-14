import AppKit

/// Focused "Captions" action. On open it transcribes the source (reusing a cached transcript so
/// it never re-charges), shows the timed, editable lines in a full-width tab under the video, and
/// lets you pick the language. Generate preview burns the current lines into a final video.
@available(macOS 12.3, *)
final class CaptionsActionController: ActionPreviewController {

    private var config: Captions.Config
    private var cues: [CaptionCue]
    private let hadCache: Bool

    private var languagePopup: NSPopUpButton!
    private var subtitlesDocStack: NSStackView!
    private var cueFields: [NSTextField] = []

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
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.heightAnchor.constraint(equalToConstant: 240).isActive = true

        tabView.addTabViewItem(makeSubtitlesTab())
        tabView.addTabViewItem(makeDesignTab())
        tabView.addTabViewItem(makeLanguageTab())
        return tabView
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

    private func makeLanguageTab() -> NSTabViewItem {
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: languages.map { $0.0 })
        if let idx = languages.firstIndex(where: { $0.1 == config.language }) {
            languagePopup.selectItem(at: idx)
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.isEnabled = !config.apiKey.isEmpty

        let langLabel = NSTextField(labelWithString: "Language")
        langLabel.font = .systemFont(ofSize: 13)
        let hint = NSTextField(labelWithString: "Changing this re-transcribes the audio.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let row = NSStackView(views: [langLabel, languagePopup])
        row.orientation = .horizontal
        row.spacing = 10
        let stack = NSStackView(views: [row, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        let tab = NSTabViewItem(identifier: "language")
        tab.label = "Language"
        tab.view = container
        return tab
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

        let updateButton = NSButton(title: "Update subtitles", target: self, action: #selector(updateSubtitles))
        updateButton.bezelStyle = .rounded

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
            cueFields.append(field)

            let row = NSStackView(views: [time, field])
            row.orientation = .horizontal
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            doc.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -16).isActive = true
        }
    }

    // MARK: - Lifecycle

    override func windowDidAppear() {
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

    @objc private func updateSubtitles() {
        applyEdits()
        Captions.saveTranscript(cues, for: source)
        try? Captions.writeSRT(cues, to: source.deletingPathExtension().appendingPathExtension("srt"))
        try? Captions.writeVTT(cues, to: source.deletingPathExtension().appendingPathExtension("vtt"))
        rebuildSubtitleRows()
        setStatus("Subtitles updated. Generate preview to burn them in.", isError: false)
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
