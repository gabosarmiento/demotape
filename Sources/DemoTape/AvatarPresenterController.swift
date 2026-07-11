import AppKit
import AVFoundation
import UserNotifications

/// Workflow window for turning a voiceover video into an avatar-presenter video.
///
/// Flow: pick a library avatar (auto-matched to the narration voice's gender) or upload a photo,
/// confirm the cost estimate, then DemoTape uploads the ElevenLabs narration + (padded) photo to
/// HeyGen, generates a photorealistic avatar, and composites it as a webcam-style circle over the
/// voiceover — producing `…avatar.mp4`. The narration sidecar is kept for re-generation.
///
/// Opt-in, bring-your-own HeyGen key. Only the narration audio (and, for photo avatars, your
/// photo) is uploaded — never the screen recording.
@available(macOS 12.3, *)
final class AvatarPresenterController: NSObject, NSWindowDelegate {

    private let voiceoverVideo: URL
    private let narrationAudio: URL
    private let apiKey: String
    private let voiceGender: String        // "male"/"female"/"" — from the narration voice
    private var onClose: (() -> Void)?

    private var window: NSWindow?
    private var sourcePopup: NSPopUpButton!     // Library avatar / Upload photo
    private var avatarPopup: NSPopUpButton!
    private var choosePhotoButton: NSButton!
    private var photoLabel: NSTextField!
    private var motionField: NSTextField!
    private var qualityPopup: NSPopUpButton!
    private var estimateLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var generateButton: NSButton!

    private var avatars: [AvatarDescriptor] = []
    private var photoURL: URL?
    private var cancelledFlag = false
    private var durationSeconds: Double = 0

    init(voiceoverVideo: URL, narrationAudio: URL, apiKey: String, voiceGender: String) {
        self.voiceoverVideo = voiceoverVideo
        self.narrationAudio = narrationAudio
        self.apiKey = apiKey
        self.voiceGender = voiceGender
        self.durationSeconds = CMTimeGetSeconds(AVAsset(url: voiceoverVideo).duration)
    }

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let w: CGFloat = 520, h: CGFloat = 470
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Avatar Presenter"
        win.isReleasedWhenClosed = false
        win.delegate = self
        let c = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let leftX: CGFloat = 24, fieldX: CGFloat = 130
        var y = h - 44

        let header = NSTextField(labelWithString: "Generate Avatar Presenter")
        header.font = .systemFont(ofSize: 16, weight: .semibold)
        header.frame = NSRect(x: leftX, y: y, width: w - 48, height: 22); c.addSubview(header)
        y -= 22
        let sub = NSTextField(wrappingLabelWithString:
            "A photorealistic presenter lip-synced to your ElevenLabs voiceover, placed where your "
            + "webcam sits. Only the narration audio (and your photo, if used) is uploaded — never "
            + "the screen recording.")
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: leftX, y: y - 34, width: w - 48, height: 34); c.addSubview(sub)
        y -= 52

        addLabel("Avatar", y: y, x: leftX, on: c)
        sourcePopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y - 4, width: 180, height: 26))
        sourcePopup.addItems(withTitles: ["Library avatar", "Upload a photo…"])
        sourcePopup.target = self; sourcePopup.action = #selector(sourceChanged)
        c.addSubview(sourcePopup)
        y -= 36

        avatarPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y, width: w - fieldX - 24, height: 26))
        avatarPopup.addItem(withTitle: "Loading avatars…"); avatarPopup.isEnabled = false
        c.addSubview(avatarPopup)

        choosePhotoButton = NSButton(title: "Choose Photo…", target: self, action: #selector(choosePhoto))
        choosePhotoButton.bezelStyle = .rounded
        choosePhotoButton.frame = NSRect(x: fieldX, y: y, width: 140, height: 28)
        choosePhotoButton.isHidden = true
        c.addSubview(choosePhotoButton)
        photoLabel = NSTextField(labelWithString: "")
        photoLabel.font = .systemFont(ofSize: 11); photoLabel.textColor = .secondaryLabelColor
        photoLabel.frame = NSRect(x: fieldX + 150, y: y + 4, width: 220, height: 18)
        photoLabel.isHidden = true
        c.addSubview(photoLabel)
        y -= 40

        addLabel("Motion", y: y, x: leftX, on: c)
        motionField = NSTextField(frame: NSRect(x: fieldX, y: y - 4, width: w - fieldX - 24, height: 24))
        motionField.placeholderString = "Optional body-motion prompt (photo avatars)"
        motionField.stringValue = AvatarSettings.motionPrompt
        c.addSubview(motionField)
        y -= 36

        addLabel("Quality", y: y, x: leftX, on: c)
        qualityPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y - 4, width: 200, height: 26))
        qualityPopup.addItems(withTitles: AvatarQuality.allCases.map { $0.label })
        qualityPopup.selectItem(at: AvatarQuality.allCases.firstIndex(of: AvatarSettings.quality) ?? 0)
        c.addSubview(qualityPopup)
        y -= 40

        // Cost/time estimate — the key guardrail.
        estimateLabel = NSTextField(wrappingLabelWithString: estimateText())
        estimateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        estimateLabel.frame = NSRect(x: leftX, y: y - 34, width: w - 48, height: 36)
        c.addSubview(estimateLabel)
        y -= 44

        spinner = NSProgressIndicator(frame: NSRect(x: leftX, y: 22, width: 18, height: 18))
        spinner.style = .spinning; spinner.isDisplayedWhenStopped = false
        c.addSubview(spinner)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: leftX + 26, y: 22, width: 240, height: 18)
        c.addSubview(statusLabel)

        generateButton = NSButton(title: "Generate…", target: self, action: #selector(generate))
        generateButton.bezelStyle = .rounded; generateButton.keyEquivalent = "\r"
        generateButton.frame = NSRect(x: w - 130, y: 16, width: 106, height: 32)
        c.addSubview(generateButton)
        let cancel = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: w - 230, y: 16, width: 94, height: 32)
        c.addSubview(cancel)

        win.contentView = c
        self.window = win
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        loadAvatars()
    }

    // MARK: - Cost estimate

    /// HeyGen Avatar IV ≈ 20 credits/minute (duration rounded up to 30s). Creator ≈ $0.05/credit.
    private func estimateText() -> String {
        let mins = max(0.5, (durationSeconds / 30.0).rounded(.up) * 0.5)
        let credits = Int((mins * 20).rounded())
        let dollars = Double(credits) * 0.05
        let base = String(format: "Estimated: ~%.1f min → ~%d HeyGen credits (~$%.2f). Rendering takes a few minutes.",
                          mins, credits, dollars)
        if durationSeconds > 300 { return "⚠︎ Long video (\(Int(durationSeconds))s). " + base + " Best kept under ~2 min." }
        if durationSeconds > 120 { return "⚠︎ " + base + " Best kept under ~2 min." }
        return base
    }

    // MARK: - Avatars

    private func loadAvatars() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let list = try HeyGenAvatarProvider(apiKey: self.apiKey).listAvatars().filter { !$0.isPremium }
                DispatchQueue.main.async { self.populate(list) }
            } catch {
                DispatchQueue.main.async {
                    self.avatarPopup.removeAllItems(); self.avatarPopup.addItem(withTitle: "—")
                    self.status("Couldn't load avatars.", .systemRed)
                }
            }
        }
    }

    private func populate(_ list: [AvatarDescriptor]) {
        avatars = list
        avatarPopup.removeAllItems()
        avatarPopup.addItems(withTitles: list.map { $0.name })
        avatarPopup.isEnabled = true
        // Auto-match the narration voice's gender so the user doesn't have to think.
        let wanted = voiceGender.lowercased()
        if !wanted.isEmpty, let idx = list.firstIndex(where: { ($0.gender ?? "").lowercased() == wanted }) {
            avatarPopup.selectItem(at: idx)
        } else if let saved = list.firstIndex(where: { $0.id == AvatarSettings.avatarId }) {
            avatarPopup.selectItem(at: saved)
        }
        status("\(list.count) avatars\(wanted.isEmpty ? "" : " · matched to your \(wanted) voice")", .secondaryLabelColor)
    }

    // MARK: - Actions

    @objc private func sourceChanged() {
        let usePhoto = sourcePopup.indexOfSelectedItem == 1
        avatarPopup.isHidden = usePhoto
        choosePhotoButton.isHidden = !usePhoto
        photoLabel.isHidden = !usePhoto
    }

    @objc private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        photoURL = url
        photoLabel.stringValue = url.lastPathComponent
        photoLabel.isHidden = false
    }

    @objc private func generate() {
        let usePhoto = sourcePopup.indexOfSelectedItem == 1
        if usePhoto && photoURL == nil { status("Choose a photo first.", .systemOrange); return }
        if !usePhoto && (avatars.isEmpty || avatarPopup.indexOfSelectedItem < 0) {
            status("Pick an avatar first.", .systemOrange); return
        }

        // Cost confirmation — the guardrail.
        let confirm = NSAlert()
        confirm.messageText = "Generate avatar presenter?"
        confirm.informativeText = estimateText()
            + "\n\nThis uses your HeyGen credits. Only the narration audio"
            + (usePhoto ? " and your photo" : "") + " are uploaded — never your screen recording."
        confirm.addButton(withTitle: "Generate")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        AvatarSettings.motionPrompt = motionField.stringValue
        AvatarSettings.quality = AvatarQuality.allCases[max(0, qualityPopup.indexOfSelectedItem)]
        let quality = AvatarSettings.quality
        let motion = motionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: AvatarSource
        if usePhoto { source = .photo(imageAssetID: "") }   // resolved after upload
        else {
            let a = avatars[avatarPopup.indexOfSelectedItem]
            AvatarSettings.avatarId = a.id; AvatarSettings.avatarName = a.name
            source = .avatar(id: a.id)
        }

        cancelledFlag = false
        setBusy(true, "Starting…")
        generateButton.title = "Cancel"
        generateButton.action = #selector(cancel)
        Notifier.shared.avatarStarted()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runPipeline(source: source, photo: usePhoto ? self?.photoURL : nil,
                              quality: quality, motion: motion)
        }
    }

    @objc private func cancel() { cancelledFlag = true; status("Cancelling…", .secondaryLabelColor) }

    // MARK: - Pipeline (background thread)

    private func runPipeline(source: AvatarSource, photo: URL?, quality: AvatarQuality, motion: String) {
        let provider = HeyGenAvatarProvider(apiKey: apiKey, isCancelled: { [weak self] in self?.cancelledFlag ?? false })
        var tempFiles: [URL] = []
        func cleanup() { tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            // 1) Resolve the avatar source (upload photo if needed).
            var resolvedSource = source
            if let photo = photo {
                progress("Preparing photo…")
                let padded = AvatarImagePrep.paddedForHeadroom(photo)
                if padded != photo { tempFiles.append(padded) }
                progress("Uploading photo…")
                let imageAsset = try provider.uploadImage(padded)
                resolvedSource = .photo(imageAssetID: imageAsset)
            }
            try checkCancel()

            // 2) Upload the narration audio (HeyGen needs mp3/wav → convert the m4a sidecar).
            progress("Uploading narration…")
            let wav = try narrationAsWav(narrationAudio); tempFiles.append(wav)
            let audioAsset = try provider.uploadAudio(wav)
            try checkCancel()

            // 3) Create the avatar video.
            progress("Generating avatar (this takes a few minutes)…")
            var request = AvatarGenerationRequest(source: resolvedSource, audioAssetID: audioAsset,
                                                  backgroundHex: AvatarSettings.chromaKeyHex, resolution: quality)
            if case .avatar = resolvedSource { request.engine = "avatar_iii" }   // stock avatars
            if case .photo = resolvedSource, !motion.isEmpty { request.motionPrompt = motion }
            let job = try provider.createVideo(request, idempotencyKey: UUID().uuidString)

            // 4) Poll with bounded backoff.
            var delay: TimeInterval = 4, waited: TimeInterval = 0
            var resultURL: URL?
            while waited < 900 {
                try checkCancel()
                switch try provider.jobStatus(job.id) {
                case .completed(let url): resultURL = url
                case .failed(let m): throw AvatarProviderError.badResult(m)
                case .pending, .processing: break
                }
                if resultURL != nil { break }
                Thread.sleep(forTimeInterval: delay); waited += delay; delay = min(delay * 1.5, 20)
                progress("Generating avatar… (\(Int(waited))s)")
            }
            guard let url = resultURL else { throw AvatarProviderError.badResult("timed out") }

            // 5) Download.
            progress("Downloading…")
            let downloaded = FileManager.default.temporaryDirectory
                .appendingPathComponent("demotape-avatar-\(UUID().uuidString).mp4")
            tempFiles.append(downloaded)
            try provider.downloadResult(url, to: downloaded)
            try checkCancel()

            // 6) Composite over the voiceover as a circle at the webcam slot.
            progress("Compositing over your demo…")
            var layout = AvatarCompositor.Layout()
            layout.shape = .circle
            layout.centerX = CGFloat(Settings.webcamPositionX)
            layout.centerY = CGFloat(Settings.webcamPositionY)
            layout.diameterFraction = CGFloat(Settings.webcamSize)
            let out = outputURL()
            try AvatarCompositor(remover: ChromaKeyRemover(hex: AvatarSettings.chromaKeyHex))
                .compose(screen: voiceoverVideo, avatar: downloaded, to: out, layout: layout,
                         isCancelled: { [weak self] in self?.cancelledFlag ?? false })

            cleanup()   // keep the narration sidecar; remove only temp upload/download/intermediate files
            DispatchQueue.main.async {
                self.setBusy(false, "Saved \(out.lastPathComponent)")
                self.resetGenerateButton()
                Notifier.shared.avatarReady(url: out)
                NSWorkspace.shared.activateFileViewerSelecting([out])
                self.window?.close()
            }
        } catch let e as AvatarProviderError where e == .cancelled {
            cleanup()
            DispatchQueue.main.async { self.setBusy(false, "Cancelled."); self.resetGenerateButton() }
        } catch {
            cleanup()
            DispatchQueue.main.async {
                self.setBusy(false, ""); self.resetGenerateButton()
                let a = NSAlert(); a.messageText = "Avatar generation failed"
                a.informativeText = error.localizedDescription; a.runModal()
            }
        }
    }

    private func checkCancel() throws { if cancelledFlag { throw AvatarProviderError.cancelled } }

    /// `<base>.avatar.mp4` next to the voiceover.
    private func outputURL() -> URL {
        let base = voiceoverVideo.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".voiceover", with: "")
        return voiceoverVideo.deletingLastPathComponent().appendingPathComponent("\(base).avatar.mp4")
    }

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

    // MARK: - UI helpers

    private func addLabel(_ t: String, y: CGFloat, x: CGFloat, on v: NSView) {
        let l = NSTextField(labelWithString: t); l.font = .systemFont(ofSize: 12); l.alignment = .right
        l.frame = NSRect(x: x - 76, y: y, width: 72, height: 18); v.addSubview(l)
    }
    private func status(_ t: String, _ color: NSColor) { statusLabel.stringValue = t; statusLabel.textColor = color }
    private func progress(_ t: String) { DispatchQueue.main.async { self.status(t, .secondaryLabelColor) } }
    private func setBusy(_ busy: Bool, _ msg: String) {
        status(msg, .secondaryLabelColor)
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        [sourcePopup, avatarPopup, choosePhotoButton, motionField, qualityPopup].forEach { $0?.isEnabled = !busy }
    }
    private func resetGenerateButton() {
        generateButton.title = "Generate…"; generateButton.action = #selector(generate)
    }

    @objc private func closeWindow() { window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil; onClose?(); onClose = nil }
}
