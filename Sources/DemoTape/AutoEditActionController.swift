import AppKit
import AVFoundation

/// Focused "Auto-Edit" action — one place to re-edit the latest recording. The first choice is
/// the **smart local director** (cuts between screen and webcam from your clicks/pauses), then a
/// placeholder for the upcoming **AI** edit, then the paced **templates**. All render through the
/// TemplateComposer into a final file. Local, no network.
@available(macOS 12.3, *)
final class AutoEditActionController: ActionPreviewController {

    private enum Mode: Equatable { case director, ai, genre(DirectorGenre) }

    private var stylePopup: NSPopUpButton!
    private var descriptionLabel: NSTextField!
    private var modes: [Mode] = []

    override var actionTitle: String { "Auto-Edit" }
    override var nothingMessage: String { "Nothing to generate." }

    override func makeControls() -> NSView {
        stylePopup = NSPopUpButton()
        modes = []

        stylePopup.addItem(withTitle: "Smart · reads your clicks & pauses (Local)")
        modes.append(.director)
        stylePopup.addItem(withTitle: "Smart · AI — coming soon")
        modes.append(.ai)
        for g in DirectorGenre.allCases {
            stylePopup.addItem(withTitle: g.title)
            modes.append(.genre(g))
        }
        // The AI option needs an OpenAI-compatible key (same one captions use). Enable it only
        // when a key is present; otherwise show it but keep it unselectable with a hint.
        stylePopup.menu?.autoenablesItems = false
        let aiReady = Keychain.exists(account: Keychain.sttAPIKeyAccount)
        stylePopup.menu?.items[1].title = aiReady ? "Smart · AI (reads what you say + do)"
                                                   : "Smart · AI — add a key in AI Settings"
        stylePopup.menu?.items[1].isEnabled = aiReady
        stylePopup.selectItem(at: 0)
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)

        let label = NSTextField(labelWithString: "Style")
        label.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [label, stylePopup])
        row.orientation = .horizontal
        row.spacing = 10

        descriptionLabel = NSTextField(wrappingLabelWithString: "")
        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.widthAnchor.constraint(equalToConstant: 480).isActive = true

        let stack = NSStackView(views: [row, descriptionLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        return stack
    }

    override func windowDidAppear() { updateDescription() }

    @objc private func styleChanged() { updateDescription() }

    private func updateDescription() {
        switch mode(at: stylePopup.indexOfSelectedItem) {
        case .director:
            descriptionLabel.stringValue =
                "Reads your clicks, typing, and pauses and cuts between your screen and webcam "
                + "like a live director — holding on the screen while you work, cutting to you on "
                + "the pauses. Never cuts mid-click."
        case .ai:
            descriptionLabel.stringValue =
                "Reads your narration (captions) alongside your clicks and directs a full shot "
                + "list — cutting to you when you're explaining, framing close-ups on the key "
                + "lines. Uses your OpenAI-compatible key; sends only the transcript and activity "
                + "timing — never the video."
        case .genre(let g):
            descriptionLabel.stringValue = g.blurb
        }
    }

    private func mode(at index: Int) -> Mode {
        guard index >= 0, index < modes.count else { return .director }
        return modes[index]
    }

    override func render(progress: @escaping (Double) -> Void) throws -> URL? {
        let paths = SourcePaths(source: source)
        let cam = paths.camera
        let branding: URL? = {
            guard Settings.brandingEnabled, !Settings.brandingImagePath.isEmpty,
                  FileManager.default.fileExists(atPath: Settings.brandingImagePath) else { return nil }
            return URL(fileURLWithPath: Settings.brandingImagePath)
        }()

        switch mode(at: stylePopup.indexOfSelectedItem) {
        case .ai:
            return try renderAIDirector(paths: paths, cam: cam, branding: branding, progress: progress)

        case .director:
            guard let metadata = try loadMetadata(paths) else { return nil }
            let shots = ShotPlanner.local(metadata: metadata, hasWebcam: cam != nil, duration: metadata.duration)
            return try renderShots(shots, metadata: metadata, paths: paths, cam: cam,
                                   branding: branding, progress: progress)

        case .genre(let g):
            guard let metadata = try loadMetadata(paths) else { return nil }
            let shots = ShotPlanner.genre(g, metadata: metadata, hasWebcam: cam != nil, duration: metadata.duration)
            return try renderShots(shots, metadata: metadata, paths: paths, cam: cam,
                                   branding: branding, progress: progress)
        }
    }

    /// Loads the recording's event sidecar, or surfaces a friendly error and returns nil.
    private func loadMetadata(_ paths: SourcePaths) throws -> RecordingMetadata? {
        guard let eventsURL = paths.events else {
            DispatchQueue.main.async { self.setStatus("No event timeline for this file — record fresh to auto-edit.", isError: true) }
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingMetadata.self, from: Data(contentsOf: eventsURL))
    }

    private func renderShots(_ shots: [DirectorShot], metadata: RecordingMetadata, paths: SourcePaths,
                             cam: URL?, branding: URL?, progress: @escaping (Double) -> Void) throws -> URL? {
        // Compose from the RAW recording with a clean screen program (cursor + click-zoom, no
        // baked-in webcam), so the director owns the composition — split-screen shows the
        // presenter once, never a redundant bubble. Falls back to the styled source if the raw
        // recording isn't available.
        //
        // The clean screen is cached (keyed by the recording) and reused across style changes, so
        // only the first generate pays the extra render pass — trying other styles is fast.
        var screenSource = source
        if let raw = paths.rawRecording {
            let clean = FileManager.default.temporaryDirectory
                .appendingPathComponent("demotape-clean-\(paths.base).mp4")
            if !isFresh(clean, comparedTo: raw) {
                DispatchQueue.main.async { self.setStatus("Preparing clean screen (first time only)…", isError: false) }
                try VideoRenderer().render(videoURL: raw, metadata: metadata, cameraURL: cam,
                                           to: clean, style: cleanScreenStyle())
            }
            screenSource = clean
        }

        let out = paths.output(suffix: "director")
        try DirectorComposer().compose(screen: screenSource, webcam: cam,
                                       cameraOffset: metadata.cameraStartOffset ?? 0,
                                       shots: shots, brandingURL: branding, to: out, progress: progress)
        return out
    }

    /// Whether `cached` exists and is at least as new as `source` (so we can reuse it).
    private func isFresh(_ cached: URL, comparedTo source: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cached.path),
              let c = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let s = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return false }
        return c >= s
    }

    /// A styled screen program with the webcam PiP disabled (the director adds the presenter
    /// itself). Mirrors the app's normal styling from Settings, minus branding (added later).
    private func cleanScreenStyle() -> VideoRenderer.Style {
        var s = VideoRenderer.Style()
        s.webcamOverlay = false
        if !Settings.autoZoomEnabled { s.maxZoom = 1.0 }
        s.useBackground = Settings.useRegion && Settings.framedBackground
        if s.useBackground {
            let name = Settings.backgroundFile
            if name.hasPrefix("/"), FileManager.default.fileExists(atPath: name) {
                s.backgroundImageURL = URL(fileURLWithPath: name)
            } else if let bundled = Bundle.main.resourceURL?.appendingPathComponent("background/\(name)"),
                      FileManager.default.fileExists(atPath: bundled.path) {
                s.backgroundImageURL = bundled
            }
        }
        if Settings.useRegion, let target = AreaPreset.named(Settings.regionPreset).targetSize {
            s.exportSize = target
        }
        return s
    }

    // MARK: - AI director

    private func renderAIDirector(paths: SourcePaths, cam: URL?, branding: URL?,
                                  progress: @escaping (Double) -> Void) throws -> URL? {
        guard cam != nil else {
            DispatchQueue.main.async { self.setStatus("The AI director needs a webcam recording to cut to.", isError: true) }
            return nil
        }
        guard let eventsURL = paths.events else {
            DispatchQueue.main.async { self.setStatus("No event timeline for this file — record fresh.", isError: true) }
            return nil
        }
        let key = Keychain.get(account: Keychain.sttAPIKeyAccount) ?? ""
        guard !key.isEmpty else {
            DispatchQueue.main.async { self.setStatus("Add your OpenAI-compatible key in AI Settings.", isError: true) }
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RecordingMetadata.self, from: Data(contentsOf: eventsURL))

        // Transcript: reuse the cache, else transcribe once (paid STT).
        DispatchQueue.main.async { self.setStatus("Transcribing…", isError: false) }
        let sttConfig = Captions.Config(baseURL: Settings.sttBaseURL, model: Settings.sttModel,
                                        apiKey: key, language: Settings.sttLanguage)
        let cues: [CaptionCue]
        if let cached = Captions.loadTranscript(for: source), !cached.isEmpty {
            cues = cached
        } else {
            cues = try Captions().generate(for: source, config: sttConfig).cues
        }

        // Ask the model to direct a full shot list, then render it from both feeds.
        DispatchQueue.main.async { self.setStatus("Directing with AI…", isError: false) }
        let llmConfig = LLMDirector.Config(baseURL: Settings.sttBaseURL,
                                           model: Settings.aiDirectorModel, apiKey: key)
        let raw = try LLMDirector().requestShots(config: llmConfig, metadata: metadata, cues: cues)
        let shots = ShotPlanner.sanitize(raw, duration: metadata.duration)
        return try renderShots(shots, metadata: metadata, paths: paths, cam: cam,
                               branding: branding, progress: progress)
    }
}
