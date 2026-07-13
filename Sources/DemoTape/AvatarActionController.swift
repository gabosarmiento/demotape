import AppKit
import AVFoundation

/// Focused "Avatar Presenter" action. Turns the voiceover into a photorealistic presenter
/// (library avatar or your photo), lip-synced to the narration and composited into the webcam
/// circle — producing a final `…avatar.mp4`. Paid (HeyGen); a cost estimate is confirmed first.
/// Only the narration audio (and your photo, if used) is uploaded — never the screen recording.
@available(macOS 12.3, *)
final class AvatarActionController: ActionPreviewController {

    private let apiKey: String
    private let voiceGender: String
    private var durationSeconds: Double = 0

    private var sourcePopup: NSPopUpButton!
    private var avatarPopup: NSPopUpButton!
    private var avatarRow: NSStackView!
    private var choosePhotoButton: NSButton!
    private var photoLabel: NSTextField!
    private var photoThumb: NSImageView!
    private var photoRow: NSStackView!
    private var motionField: NSTextField!
    private var motionRow: NSStackView!
    private var estimateLabel: NSTextField!

    private var avatars: [AvatarDescriptor] = []
    private var avatarsLoaded = false
    private var photoURL: URL?

    init(source: URL, apiKey: String, voiceGender: String) {
        self.apiKey = apiKey
        self.voiceGender = voiceGender
        super.init(source: source)
        self.durationSeconds = CMTimeGetSeconds(AVAsset(url: source).duration)
    }

    override var actionTitle: String { "Avatar Presenter" }
    override var controlsFillWidth: Bool { true }

    // MARK: - Controls

    override func makeControls() -> NSView {
        sourcePopup = NSPopUpButton()
        sourcePopup.addItems(withTitles: ["Library avatar", "Upload a photo…"])
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceKindChanged)
        let sourceRow = labeled("Avatar", sourcePopup)

        avatarPopup = NSPopUpButton()
        avatarPopup.addItem(withTitle: "—")
        avatarPopup.isEnabled = false
        avatarRow = labeled("Library", avatarPopup)

        choosePhotoButton = NSButton(title: "Choose Photo…", target: self, action: #selector(choosePhoto))
        choosePhotoButton.bezelStyle = .rounded
        photoThumb = NSImageView()
        photoThumb.imageScaling = .scaleProportionallyUpOrDown
        photoThumb.wantsLayer = true
        photoThumb.layer?.cornerRadius = 8
        photoThumb.layer?.masksToBounds = true
        photoThumb.translatesAutoresizingMaskIntoConstraints = false
        photoThumb.widthAnchor.constraint(equalToConstant: 64).isActive = true
        photoThumb.heightAnchor.constraint(equalToConstant: 64).isActive = true
        photoThumb.isHidden = true
        photoLabel = NSTextField(labelWithString: "No photo chosen")
        photoLabel.font = .systemFont(ofSize: 11)
        photoLabel.textColor = .secondaryLabelColor
        photoRow = labeled("Photo", stack([choosePhotoButton, photoThumb, photoLabel], spacing: 10))

        motionField = NSTextField()
        motionField.placeholderString = "Optional motion prompt"
        motionField.stringValue = AvatarSettings.motionPrompt
        motionField.translatesAutoresizingMaskIntoConstraints = false
        motionField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        motionRow = labeled("Motion", motionField)

        estimateLabel = NSTextField(wrappingLabelWithString: estimateText())
        estimateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        estimateLabel.alignment = .center

        let stackView = NSStackView(views: [sourceRow, avatarRow, photoRow, motionRow, estimateLabel])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        return stackView
    }

    override func windowDidAppear() {
        sourcePopup.selectItem(at: 1)   // default to the instant photo flow
        sourceKindChanged()
        setStatus("Choose a photo or a library avatar, then Generate preview.", isError: false)
    }

    // MARK: - Layout helpers

    private func labeled(_ title: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 12)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 70).isActive = true
        return stack([l, control], spacing: 10)
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        return s
    }

    // MARK: - Source kind

    @objc private func sourceKindChanged() {
        let usePhoto = sourcePopup.indexOfSelectedItem == 1
        avatarRow.isHidden = usePhoto                 // library picker only for library avatars
        photoRow.isHidden = !usePhoto                 // photo + motion only for photos
        motionRow.isHidden = !usePhoto
        if !usePhoto && !avatarsLoaded { loadAvatars() }
    }

    private func loadAvatars() {
        avatarsLoaded = true
        avatarPopup.removeAllItems()
        avatarPopup.addItem(withTitle: "Loading avatars…")
        avatarPopup.isEnabled = false
        setStatus("Loading avatars…", isError: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let list = try HeyGenAvatarProvider(apiKey: self.apiKey).listAvatars().filter { !$0.isPremium }
                DispatchQueue.main.async { self.populate(list) }
            } catch {
                DispatchQueue.main.async {
                    self.avatarsLoaded = false
                    self.avatarPopup.removeAllItems(); self.avatarPopup.addItem(withTitle: "—")
                    self.setStatus("Couldn't load avatars: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func populate(_ list: [AvatarDescriptor]) {
        avatars = list
        avatarPopup.removeAllItems()
        avatarPopup.addItems(withTitles: list.map { $0.name })
        avatarPopup.isEnabled = true
        let wanted = voiceGender.lowercased()
        if !wanted.isEmpty, let idx = list.firstIndex(where: { ($0.gender ?? "").lowercased() == wanted }) {
            avatarPopup.selectItem(at: idx)
        } else if let saved = list.firstIndex(where: { $0.id == AvatarSettings.avatarId }) {
            avatarPopup.selectItem(at: saved)
        }
        setStatus("\(list.count) avatars\(wanted.isEmpty ? "" : " · matched to your \(wanted) voice").",
                  isError: false)
    }

    @objc private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        photoURL = url
        photoLabel.stringValue = url.lastPathComponent
        photoThumb.image = NSImage(contentsOf: url)
        photoThumb.isHidden = (photoThumb.image == nil)
    }

    // MARK: - Cost estimate + confirmation

    private func estimateText() -> String {
        let mins = max(0.5, (durationSeconds / 30.0).rounded(.up) * 0.5)
        let credits = Int((mins * 20).rounded())
        let dollars = Double(credits) * 0.05
        let base = String(format: "Estimated ~%.1f min → ~%d HeyGen credits (~$%.2f). Rendering takes a few minutes.",
                          mins, credits, dollars)
        if durationSeconds > 300 { return "⚠︎ Long clip (\(Int(durationSeconds))s). " + base + " Best under ~2 min." }
        if durationSeconds > 120 { return "⚠︎ " + base + " Best under ~2 min." }
        return base
    }

    override func confirmBeforeGenerate() -> Bool {
        let usePhoto = sourcePopup.indexOfSelectedItem == 1
        if usePhoto && photoURL == nil { setStatus("Choose a photo first.", isError: true); return false }
        if !usePhoto && (avatars.isEmpty || avatarPopup.indexOfSelectedItem < 0) {
            setStatus("Pick an avatar first.", isError: true); return false
        }
        let confirm = NSAlert()
        confirm.messageText = "Generate avatar presenter?"
        confirm.informativeText = estimateText()
            + "\n\nThis uses your HeyGen credits. Only the narration audio"
            + (usePhoto ? " and your photo" : "") + " are uploaded — never your screen recording."
        confirm.addButton(withTitle: "Generate")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return false }
        Notifier.shared.avatarStarted()
        return true
    }

    // MARK: - Pipeline (Generate preview → final file)

    override func render(progress: @escaping (Double) -> Void) throws -> URL? {
        let narration = source.deletingPathExtension().appendingPathExtension("narration.m4a")
        guard FileManager.default.fileExists(atPath: narration.path) else {
            throw SimpleError("This file has no narration sidecar — open the avatar step on a voiceover video.")
        }

        let usePhoto = sourcePopup.indexOfSelectedItem == 1
        AvatarSettings.motionPrompt = motionField.stringValue
        // Fixed at 720p — plenty for a webcam-circle PiP, and it saves credits. Not user-tunable.
        let quality = AvatarQuality.p720
        let motion = motionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        var avatarSource: AvatarSource
        if usePhoto {
            avatarSource = .photo(imageAssetID: "")
        } else {
            let a = avatars[avatarPopup.indexOfSelectedItem]
            AvatarSettings.avatarId = a.id; AvatarSettings.avatarName = a.name
            avatarSource = .avatar(id: a.id)
        }

        let provider = HeyGenAvatarProvider(apiKey: apiKey, isCancelled: { [weak self] in self?.isCancelled ?? true })
        var tempFiles: [URL] = []
        defer { tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        // 1) Resolve source (upload photo if needed).
        if usePhoto, let photo = photoURL {
            stage("Preparing photo…")
            let padded = AvatarImagePrep.paddedForHeadroom(photo)
            if padded != photo { tempFiles.append(padded) }
            stage("Uploading photo…")
            avatarSource = .photo(imageAssetID: try provider.uploadImage(padded))
        }
        try bail()

        // 2) Upload narration (convert m4a → wav).
        stage("Uploading narration…")
        let wav = try narrationAsWav(narration); tempFiles.append(wav)
        let audioAsset = try provider.uploadAudio(wav)
        try bail()

        // 3) Create the avatar video.
        stage("Generating avatar (this takes a few minutes)…")
        var request = AvatarGenerationRequest(source: avatarSource, audioAssetID: audioAsset,
                                              backgroundHex: AvatarSettings.chromaKeyHex, resolution: quality)
        if case .avatar = avatarSource { request.engine = "avatar_iii" }
        if case .photo = avatarSource, !motion.isEmpty { request.motionPrompt = motion }
        let job = try provider.createVideo(request, idempotencyKey: UUID().uuidString)

        // 4) Poll with bounded backoff.
        var delay: TimeInterval = 4, waited: TimeInterval = 0
        var resultURL: URL?
        while waited < 900 {
            try bail()
            switch try provider.jobStatus(job.id) {
            case .completed(let url): resultURL = url
            case .failed(let m): throw AvatarProviderError.badResult(m)
            case .pending, .processing: break
            }
            if resultURL != nil { break }
            Thread.sleep(forTimeInterval: delay); waited += delay; delay = min(delay * 1.5, 20)
            stage("Generating avatar… (\(Int(waited))s)")
        }
        guard let remoteURL = resultURL else { throw AvatarProviderError.badResult("timed out") }

        // 5) Download.
        stage("Downloading…")
        let downloaded = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-avatar-\(UUID().uuidString).mp4")
        tempFiles.append(downloaded)
        try provider.downloadResult(remoteURL, to: downloaded)
        try bail()

        // 6) Composite over the voiceover as a circle at the webcam slot.
        stage("Compositing over your demo…")
        var layout = AvatarCompositor.Layout()
        layout.shape = .circle
        layout.centerX = CGFloat(Settings.webcamPositionX)
        layout.centerY = CGFloat(Settings.webcamPositionY)
        layout.diameterFraction = CGFloat(Settings.webcamSize)
        let out = SourcePaths(source: source).output(suffix: "avatar")
        try AvatarCompositor(remover: ChromaKeyRemover(hex: AvatarSettings.chromaKeyHex))
            .compose(screen: source, avatar: downloaded, to: out, layout: layout,
                     isCancelled: { [weak self] in self?.isCancelled ?? true })

        DispatchQueue.main.async { Notifier.shared.avatarReady(url: out) }
        return out
    }

    private func bail() throws { if isCancelled { throw AvatarProviderError.cancelled } }
    private func stage(_ text: String) { DispatchQueue.main.async { self.setStatus(text, isError: false) } }

    /// HeyGen assets accept mp3/wav (not m4a) — convert the narration sidecar to a temp WAV.
    private func narrationAsWav(_ m4a: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-narration-\(UUID().uuidString).wav")
        let input = try AVAudioFile(forReading: m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: input.fileFormat.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let output = try AVAudioFile(forWriting: out, settings: settings)
        let cap = AVAudioFrameCount(input.processingFormat.sampleRate * 2)
        while input.framePosition < input.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: cap) else { break }
            try input.read(into: buf)
            if buf.frameLength == 0 { break }
            try output.write(from: buf)
        }
        return out
    }
}
