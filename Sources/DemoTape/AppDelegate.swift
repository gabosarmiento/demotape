import AppKit
import Carbon.HIToolbox

@available(macOS 12.3, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = RecordingEngine()
    private let countdown = CountdownController()
    private let hotKey = GlobalHotKey()

    private enum State { case idle, countdown, recording, rendering }
    private var state: State = .idle { didSet { refreshUI(); updateRecorderBarForState() } }

    private var recorderBar: RecorderBarController?
    private var regionOverlay: RegionOverlay?
    private var whileIdleItems: [NSMenuItem] = []

    private lazy var startItem = NSMenuItem(
        title: "Start Recording  (⇧⌘S)", action: #selector(startRecording), keyEquivalent: "")
    private lazy var stopItem = NSMenuItem(
        title: "Stop Recording  (⇧⌘S)", action: #selector(stopRecording), keyEquivalent: "")
    private lazy var fullScreenItem = NSMenuItem(
        title: "Record Full Screen", action: #selector(selectFullScreen), keyEquivalent: "")
    private lazy var selectAreaItem = NSMenuItem(
        title: "Select Recording Area…", action: #selector(selectArea), keyEquivalent: "")
    private lazy var micItem = NSMenuItem(
        title: "Record Microphone", action: #selector(toggleMic), keyEquivalent: "")
    private lazy var webcamItem = NSMenuItem(
        title: "Record Webcam", action: #selector(toggleWebcam), keyEquivalent: "")
    private lazy var brandingToggleItem = NSMenuItem(
        title: "Enable Branding", action: #selector(toggleBranding), keyEquivalent: "")
    private lazy var teleprompterToggleItem = NSMenuItem(
        title: "Enable Teleprompter", action: #selector(toggleTeleprompter), keyEquivalent: "")
    private lazy var noBackgroundItem = NSMenuItem(
        title: "No Background", action: #selector(toggleNoBackground), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        // Brand the app icon (used by Finder and by NSAlert dialogs).
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        // Critical: NSMenu auto-enables items by default, which ignores our manual
        // isEnabled flags. Turn it off so Start/Stop reflect the real state.
        menu.autoenablesItems = false

        // --- Record ---
        startItem.target = self
        stopItem.target = self
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())

        // --- Capture mode ---
        menu.addItem(sectionHeader("Capture"))
        fullScreenItem.target = self
        menu.addItem(fullScreenItem)
        selectAreaItem.target = self
        menu.addItem(selectAreaItem)
        menu.addItem(.separator())

        // --- Input (submenu: mic / webcam, then webcam settings) ---
        micItem.target = self
        micItem.state = Settings.captureMicrophone ? .on : .off
        webcamItem.target = self
        webcamItem.state = Settings.captureWebcam ? .on : .off
        let webcamSettings = NSMenuItem(title: "Webcam Settings…",
                                        action: #selector(openWebcamSettings), keyEquivalent: "")
        webcamSettings.target = self
        let inputItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        let inputMenu = NSMenu(); inputMenu.autoenablesItems = false
        inputMenu.addItem(micItem)
        inputMenu.addItem(webcamItem)
        inputMenu.addItem(.separator())
        inputMenu.addItem(webcamSettings)
        inputItem.submenu = inputMenu
        menu.addItem(inputItem)

        // --- Background (submenu: choose an image, or No Background) ---
        let chooseBg = NSMenuItem(title: "Choose Background…",
                                  action: #selector(openBackgroundPicker), keyEquivalent: "")
        chooseBg.target = self
        noBackgroundItem.target = self
        noBackgroundItem.state = Settings.framedBackground ? .off : .on
        let backgroundItem = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        let backgroundMenu = NSMenu(); backgroundMenu.autoenablesItems = false
        backgroundMenu.addItem(chooseBg)
        backgroundMenu.addItem(.separator())
        backgroundMenu.addItem(noBackgroundItem)
        backgroundItem.submenu = backgroundMenu
        menu.addItem(backgroundItem)

        // --- Branding (submenu) — an overlay baked into the video, alongside the others ---
        brandingToggleItem.target = self
        brandingToggleItem.state = Settings.brandingEnabled ? .on : .off
        let brandingSettings = NSMenuItem(title: "Branding Settings…",
                                          action: #selector(openBrandingSettings), keyEquivalent: "")
        brandingSettings.target = self
        let brandingItem = NSMenuItem(title: "Branding", action: nil, keyEquivalent: "")
        let brandingMenu = NSMenu(); brandingMenu.autoenablesItems = false
        brandingMenu.addItem(brandingToggleItem)
        brandingMenu.addItem(brandingSettings)
        brandingItem.submenu = brandingMenu
        menu.addItem(brandingItem)

        // --- Teleprompter (submenu) ---
        teleprompterToggleItem.target = self
        teleprompterToggleItem.state = Settings.teleprompterEnabled ? .on : .off
        let teleprompterSettings = NSMenuItem(title: "Teleprompter Settings…",
                                              action: #selector(openTeleprompterSettings), keyEquivalent: "")
        teleprompterSettings.target = self
        let teleprompterItem = NSMenuItem(title: "Teleprompter", action: nil, keyEquivalent: "")
        let teleprompterMenu = NSMenu(); teleprompterMenu.autoenablesItems = false
        teleprompterMenu.addItem(teleprompterToggleItem)
        teleprompterMenu.addItem(teleprompterSettings)
        teleprompterItem.submenu = teleprompterMenu
        menu.addItem(teleprompterItem)
        menu.addItem(.separator())

        // --- After recording (tighten → AI → publish) ---
        menu.addItem(sectionHeader("After Recording"))

        let tightenItem = NSMenuItem(title: "Auto-Cut & Speed Up Latest…",
                                     action: #selector(openTighten), keyEquivalent: "")
        tightenItem.target = self
        menu.addItem(tightenItem)

        // AI Features submenu (opt-in, bring-your-own-key).
        let aiItem = NSMenuItem(title: "AI Features", action: nil, keyEquivalent: "")
        let aiMenu = NSMenu()
        aiMenu.autoenablesItems = false
        let aiSettings = NSMenuItem(title: "AI Settings…",
                                    action: #selector(openAISettings), keyEquivalent: "")
        aiSettings.target = self
        aiMenu.addItem(aiSettings)
        aiMenu.addItem(.separator())
        let captionsItem = NSMenuItem(title: "Generate Captions for Latest…",
                                      action: #selector(generateCaptions), keyEquivalent: "")
        captionsItem.target = self
        aiMenu.addItem(captionsItem)
        let voiceoverItem = NSMenuItem(title: "Generate Voiceover for Latest…",
                                       action: #selector(generateVoiceover), keyEquivalent: "")
        voiceoverItem.target = self
        aiMenu.addItem(voiceoverItem)
        aiItem.submenu = aiMenu
        menu.addItem(aiItem)

        let publishItem = NSMenuItem(title: "Web Publish Latest…",
                                     action: #selector(openWebPublish), keyEquivalent: "")
        publishItem.target = self
        menu.addItem(publishItem)
        menu.addItem(.separator())

        // --- Utility ---
        let folderItem = NSMenuItem(title: "Recording Folder", action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let openFolder = NSMenuItem(title: "Open", action: #selector(openRecordingsFolder), keyEquivalent: "o")
        openFolder.target = self
        folderMenu.addItem(openFolder)
        let changeDir = NSMenuItem(title: "Change Output Directory…",
                                   action: #selector(changeOutputDirectory), keyEquivalent: "")
        changeDir.target = self
        folderMenu.addItem(changeDir)
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit DemoTape",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Items disabled while a recording is in progress (disabling a submenu's parent
        // greys the whole submenu).
        whileIdleItems = [fullScreenItem, selectAreaItem, inputItem, backgroundItem,
                          teleprompterItem, brandingItem, tightenItem, aiItem, publishItem, changeDir]

        statusItem.menu = menu
        updateCaptureModeChecks()

        // Global ⇧⌘S toggles recording without touching the menu (so the click isn't
        // captured at the end of the video). Carbon consumes the key system-wide.
        hotKey.onPressed = { [weak self] in self?.toggleRecording() }
        hotKey.register(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))

        refreshUI()

        // Launch with the recorder bar visible in full-screen mode, ready to go. Dismiss with ✕.
        Settings.useRegion = false
        updateCaptureModeChecks()
        presentRecorderBar()
    }

    /// Menu-bar-only (accessory) apps have no application menu by default, so standard
    /// keyboard shortcuts like ⌘V/⌘C/⌘A never reach text fields in our windows. Installing
    /// a minimal main menu with an Edit menu restores Cut/Copy/Paste/Select All everywhere.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit DemoTape",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// The bundled DemoTape logo sized for the menu bar (nil when running unbundled).
    private static func menuBarLogo() -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("MenuBarIcon.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        return img
    }

    /// A small, disabled, greyed section label used to group menu items.
    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }

    @objc private func toggleRecording() {
        switch state {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .countdown, .rendering: break // ignore mid-transition
        }
    }

    // MARK: - UI state

    private func refreshUI() {
        startItem.isEnabled = (state == .idle)
        stopItem.isEnabled = (state == .recording)
        startItem.title = (state == .rendering) ? "Rendering…" : "Start Recording"
        // Grey out configuration/action items unless idle.
        let idle = (state == .idle)
        whileIdleItems.forEach { $0.isEnabled = idle }

        guard let button = statusItem.button else { return }
        // Branded logo at rest; state symbols while working so status stays clear.
        if state == .idle, let logo = Self.menuBarLogo() {
            button.image = logo
            button.title = ""
            return
        }
        let symbolName: String
        switch state {
        case .idle: symbolName = "record.circle"
        case .countdown: symbolName = "timer"
        case .recording: symbolName = "record.circle.fill"
        case .rendering: symbolName = "gearshape"
        }
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DemoTape") {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = (state == .recording) ? "● REC" : "○"
        }
    }

    // MARK: - Actions

    @objc private func startRecording() {
        guard state == .idle else { return }
        state = .countdown

        // Warm up the capture sessions concurrently with the countdown so recording
        // begins instantly at zero (no camera warm-up delay after "1").
        let prepareTask = Task { try await self.engine.prepare() }

        countdown.run(from: 3) { [weak self] in
            guard let self = self else { return }
            Task {
                do {
                    try await prepareTask.value   // ensure warm-up finished
                    self.engine.beginRecording()
                    await MainActor.run { self.state = .recording }
                } catch {
                    await MainActor.run {
                        self.state = .idle
                        self.presentPermissionHelp(title: "Can't start recording",
                                                   message: error.localizedDescription)
                    }
                }
            }
        }
    }

    @objc private func stopRecording() {
        guard state == .recording else { return }
        state = .rendering
        teleprompter.stop()
        dismissRecorderBar()   // close the bar + border; rendering starts
        Task {
            let raw = await engine.stop()
            guard let raw = raw else {
                await MainActor.run {
                    self.state = .idle
                    self.presentPermissionHelp(
                        title: "No video was captured",
                        message: "The recording was empty. This almost always means Screen Recording permission isn't granted yet.")
                }
                return
            }
            // Auto-produce the styled video (hands-off).
            let camera = self.engine.lastCameraURL
            let style = await MainActor.run { self.makeStyle() }
            let styled = self.renderStyled(from: raw, camera: camera, style: style)
            await MainActor.run {
                self.state = .idle
                self.notifySaved(at: styled ?? raw)
            }
        }
    }

    /// Renders the styled output next to the raw recording. Returns the styled URL,
    /// or nil if the sidecar/render failed (caller falls back to the raw file).
    private func renderStyled(from raw: URL, camera: URL?, style: VideoRenderer.Style) -> URL? {
        let sidecar = raw.deletingPathExtension().appendingPathExtension("events.json")
        do {
            let data = try Data(contentsOf: sidecar)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(RecordingMetadata.self, from: data)
            let styled = raw.deletingPathExtension().appendingPathExtension("styled.mp4")
            try VideoRenderer().render(videoURL: raw, metadata: metadata, cameraURL: camera, to: styled, style: style)
            return styled
        } catch {
            Log.write("renderStyled failed: \(error.localizedDescription)")
            return nil
        }
    }

    @objc private func openRecordingsFolder() {
        NSWorkspace.shared.open(Paths.outputDirectory)
    }

    @objc private func changeOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where DemoTape saves recordings."
        panel.directoryURL = Paths.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Settings.outputDirectoryPath = url.path
            NSWorkspace.shared.open(Paths.outputDirectory)
        }
    }

    @objc private func toggleBranding() {
        Settings.brandingEnabled.toggle()
        // Enabling with no logo yet? Open the editor so the user can add one.
        if Settings.brandingEnabled && Settings.brandingImagePath.isEmpty {
            Settings.brandingEnabled = false
            openBrandingSettings()
        }
        brandingToggleItem.state = Settings.brandingEnabled ? .on : .off
    }

    private let teleprompter = TeleprompterOverlay()
    @objc private func toggleTeleprompter() {
        Settings.teleprompterEnabled.toggle()
        if Settings.teleprompterEnabled && Settings.teleprompterText.trimmingCharacters(in: .whitespaces).isEmpty {
            Settings.teleprompterEnabled = false
            openTeleprompterSettings()
        } else if Settings.teleprompterEnabled && !Settings.useRegion {
            let a = NSAlert()
            a.messageText = "Teleprompter enabled"
            a.informativeText = "In full-screen recording a thin strip at the top of the screen "
                + "is reserved for the teleprompter and is NOT recorded, so leave a little "
                + "headroom in your content. (In Select Recording Area mode it scrolls in the "
                + "empty space around your selection instead.)"
            a.runModal()
        }
        teleprompterToggleItem.state = Settings.teleprompterEnabled ? .on : .off
    }

    /// The rect actually being recorded (screen coords, bottom-left), so the teleprompter can
    /// scroll in the free area outside it. Full-screen reserves a thin top strip.
    private func captureRectForTeleprompter() -> CGRect? {
        guard let f = NSScreen.main?.frame else { return nil }
        if Settings.useRegion { return regionScreenRect() }
        let (crop, _) = TeleprompterStrip.crop(width: f.width, height: f.height,
                                               edge: Settings.teleprompterStripEdge,
                                               fraction: CGFloat(Settings.teleprompterTopStripFraction))
        return crop.offsetBy(dx: f.minX, dy: f.minY)
    }

    private var teleprompterController: TeleprompterSettingsController?
    @objc private func openTeleprompterSettings() {
        let controller = TeleprompterSettingsController()
        teleprompterController = controller
        controller.show(onClose: { [weak self] in
            self?.teleprompterToggleItem.state = Settings.teleprompterEnabled ? .on : .off
            self?.teleprompterController = nil
        })
    }

    private var brandingController: BrandingSettingsController?
    @objc private func openBrandingSettings() {
        let controller = BrandingSettingsController()
        brandingController = controller
        controller.show(onClose: { [weak self] in
            self?.brandingToggleItem.state = Settings.brandingEnabled ? .on : .off
            self?.brandingController = nil
        })
    }

    private var tightenController: TightenController?
    @objc private func openTighten() {
        guard let video = latestRecording() else {
            presentPermissionHelp(title: "No recording found",
                                  message: "Record something first — this trims/speeds up your latest recording.")
            return
        }
        let controller = TightenController(video: video)
        tightenController = controller  // retain while open
        controller.show(onClose: { [weak self] in self?.tightenController = nil })
    }

    // MARK: - Captions (AI, bring-your-own-key)

    /// Newest playable recording in the output folder (prefers the styled export).
    private func latestRecording() -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Paths.outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let videos = items.filter { ["mp4", "mov"].contains($0.pathExtension.lowercased())
            && !$0.lastPathComponent.hasSuffix(".cam.mov") }
        func modified(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        // Prefer a styled export if one exists among the newest files.
        let styled = videos.filter { $0.lastPathComponent.hasSuffix(".styled.mp4") }
        return (styled.isEmpty ? videos : styled).max { modified($0) < modified($1) }
    }

    private var captionsEditor: CaptionsEditorController?
    private func showCaptionsEditor(video: URL, cues: [CaptionCue]) {
        guard !cues.isEmpty else {
            notifySaved(at: video.deletingPathExtension().appendingPathExtension("srt"))
            return
        }
        let editor = CaptionsEditorController(video: video, cues: cues)
        captionsEditor = editor  // retain while open
        editor.show(onClose: { [weak self] in self?.captionsEditor = nil })
    }

    private var voiceoverController: VoiceoverController?
    @objc private func generateVoiceover() {
        let key = Keychain.get(account: Keychain.elevenAPIKeyAccount) ?? ""
        guard Settings.aiEnabled, !key.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Add an ElevenLabs key first"
            alert.informativeText = Settings.aiEnabled
                ? "Add your ElevenLabs API key in AI Settings to generate a voiceover."
                : "Voiceover uses ElevenLabs text-to-speech. Enable AI features and add your "
                    + "ElevenLabs key in AI Settings, then try again."
            alert.addButton(withTitle: "Open AI Settings…")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { openAISettings() }
            return
        }
        guard let video = latestRecording() else {
            presentPermissionHelp(title: "No recording found",
                                  message: "Record something first — voiceover runs on your latest recording.")
            return
        }
        let controller = VoiceoverController(video: video, apiKey: key)
        voiceoverController = controller  // retain while open
        controller.show(onClose: { [weak self] in self?.voiceoverController = nil })
    }

    private var aiSettingsController: AISettingsController?
    @objc private func openAISettings() {
        let controller = AISettingsController()
        aiSettingsController = controller  // retain while open
        controller.show()
    }

    @objc private func generateCaptions() {
        guard let video = latestRecording() else {
            presentPermissionHelp(title: "No recording found",
                                  message: "Record something first — captions run on your latest recording.")
            return
        }
        // Idempotent: if we've already transcribed this recording, reuse it (no API call).
        if let cached = Captions.loadTranscript(for: video), !cached.isEmpty {
            showCaptionsEditor(video: video, cues: cached)
            return
        }
        // Gate on the AI master switch + a saved key. Otherwise, send the user to settings.
        let key = Keychain.get(account: Keychain.sttAPIKeyAccount) ?? ""
        guard Settings.aiEnabled, !key.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Turn on AI features first"
            alert.informativeText = Settings.aiEnabled
                ? "Add an API key in AI Settings to generate captions."
                : "Captions use an OpenAI-compatible speech-to-text API. Enable AI features and add "
                    + "your key in AI Settings, then try again."
            alert.addButton(withTitle: "Open AI Settings…")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { openAISettings() }
            return
        }
        let config = Captions.Config(baseURL: Settings.sttBaseURL, model: Settings.sttModel,
                                     apiKey: key, language: Settings.sttLanguage)

        state = .rendering  // reuse the "working" UI state
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try Captions().generate(for: video, config: config)
                DispatchQueue.main.async {
                    self?.state = .idle
                    self?.showCaptionsEditor(video: video, cues: result.cues)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = .idle
                    self?.presentPermissionHelp(title: "Captions failed",
                                                message: error.localizedDescription)
                }
            }
        }
    }



    @objc private func toggleMic() {
        Settings.captureMicrophone.toggle()
        micItem.state = Settings.captureMicrophone ? .on : .off
        recorderBar?.updateMic(Settings.captureMicrophone)
    }

    @objc private func toggleWebcam() {
        Settings.captureWebcam.toggle()
        webcamItem.state = Settings.captureWebcam ? .on : .off
        recorderBar?.updateWebcam(Settings.captureWebcam)
    }

    private var webcamSettingsController: WebcamSettingsController?
    @objc private func openWebcamSettings() {
        let controller = WebcamSettingsController()
        webcamSettingsController = controller // retain while open
        controller.show()
    }

    private var webPublishController: WebPublishController?
    @objc private func openWebPublish() {
        let controller = WebPublishController()
        webPublishController = controller
        controller.show()
    }

    private var backgroundPicker: BackgroundPickerController?
    @objc private func openBackgroundPicker() {
        Settings.framedBackground = true               // choosing an image implies framing on
        noBackgroundItem.state = .off
        let picker = BackgroundPickerController()
        backgroundPicker = picker
        picker.show()
    }

    @objc private func toggleNoBackground() {
        // "No Background" = don't frame the region; record it edge-to-edge at its resolution.
        Settings.framedBackground.toggle()
        noBackgroundItem.state = Settings.framedBackground ? .off : .on
    }

    private var regionSelector: RegionSelector?
    private func updateCaptureModeChecks() {
        fullScreenItem.state = Settings.useRegion ? .off : .on
        selectAreaItem.state = Settings.useRegion ? .on : .off
    }

    @objc private func selectFullScreen() {
        Settings.useRegion = false
        updateCaptureModeChecks()
        regionOverlay?.hide()
        presentRecorderBar()
    }

    @objc private func selectArea() {
        let selector = RegionSelector()
        regionSelector = selector
        selector.selectArea { [weak self] ok in
            DispatchQueue.main.async {
                self?.updateCaptureModeChecks()
                if ok { self?.presentRecorderBar() }
            }
        }
    }

    // MARK: - Recorder bar + region border

    /// Selected region in screen coordinates (bottom-left origin), matching the capture crop.
    private func regionScreenRect() -> CGRect? {
        guard Settings.useRegion, let screen = NSScreen.main else { return nil }
        let f = screen.frame
        let rx = CGFloat(Settings.regionX) * f.width
        let ryTop = CGFloat(Settings.regionY) * f.height
        let rw = CGFloat(Settings.regionW) * f.width
        let rh = CGFloat(Settings.regionH) * f.height
        return CGRect(x: f.minX + rx, y: f.minY + f.height - ryTop - rh, width: rw, height: rh)
    }

    private func presentRecorderBar() {
        if recorderBar == nil {
            let bar = RecorderBarController()
            bar.onStart = { [weak self] in self?.startRecording() }
            bar.onStop = { [weak self] in self?.stopRecording() }
            bar.onCancel = { [weak self] in self?.cancelRecorderBar() }
            bar.onToggleMic = { [weak self] in self?.toggleMic() }
            bar.onToggleWebcam = { [weak self] in self?.toggleWebcam() }
            recorderBar = bar
        }
        let region = regionScreenRect()
        if let region = region {
            if regionOverlay == nil {
                let overlay = RegionOverlay()
                overlay.onChange = { [weak self] screenRect in
                    self?.saveRegion(fromScreenRect: screenRect)
                    self?.recorderBar?.reposition(anchorRegion: screenRect)
                }
                regionOverlay = overlay
            }
            regionOverlay?.show(region: region, editable: true)  // adjustable until recording
        } else {
            regionOverlay?.hide()
        }
        recorderBar?.show(anchorRegion: region,
                          micOn: Settings.captureMicrophone, webcamOn: Settings.captureWebcam)
    }

    /// Persist a region edited on screen (bottom-left) back to normalized settings (top-left).
    private func saveRegion(fromScreenRect r: CGRect) {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        Settings.regionX = Double((r.minX - f.minX) / f.width)
        Settings.regionY = Double((f.maxY - r.maxY) / f.height)   // top offset
        Settings.regionW = Double(r.width / f.width)
        Settings.regionH = Double(r.height / f.height)
    }

    private func cancelRecorderBar() {
        guard state != .recording else { return }   // during recording, use Stop
        dismissRecorderBar()
    }

    private func dismissRecorderBar() {
        recorderBar?.hide()
        regionOverlay?.hide()
    }

    /// Keep the floating bar/border in sync with the recording state. For full-screen
    /// capture the bar is hidden during recording (it would otherwise be in the video);
    /// for region capture it stays put, outside the recorded area.
    private func updateRecorderBarForState() {
        guard recorderBar != nil else { return }
        switch state {
        case .countdown:
            // Lock the region (click-through border only) once we're about to record.
            regionOverlay?.setEditable(false)
            if !Settings.useRegion { recorderBar?.setHiddenDuringCapture(true) }
        case .recording:
            recorderBar?.setRecording(true)
            recorderBar?.relinquishKeyFocus()   // typing goes to the recorded app, not the bar
            if Settings.teleprompterEnabled {   // scroll the script in the free area outside the crop
                let minutes = TeleprompterOverlay.scrollMinutes(
                    text: Settings.teleprompterText, speed: Settings.teleprompterSpeed,
                    fit: Settings.teleprompterFitDuration, fitMinutes: Settings.teleprompterMinutes)
                teleprompter.show(text: Settings.teleprompterText, minutes: minutes,
                                  recordedRect: captureRectForTeleprompter(),
                                  edge: Settings.teleprompterStripEdge)
            }
        default:
            break
        }
    }

    /// Builds the render style from current settings (must run on the main thread —
    /// reads NSScreen / the desktop wallpaper).
    private func makeStyle() -> VideoRenderer.Style {
        var style = VideoRenderer.Style()
        style.webcamCenterX = CGFloat(Settings.webcamPositionX)
        style.webcamCenterY = CGFloat(Settings.webcamPositionY)
        style.webcamZoom = CGFloat(Settings.webcamZoom)
        style.webcamDiameterFraction = CGFloat(Settings.webcamSize)
        style.useBackground = Settings.useRegion && Settings.framedBackground
        if style.useBackground {
            style.backgroundImageURL = backgroundURL()
        }
        if Settings.brandingEnabled, !Settings.brandingImagePath.isEmpty,
           FileManager.default.fileExists(atPath: Settings.brandingImagePath) {
            style.brandingImageURL = URL(fileURLWithPath: Settings.brandingImagePath)
            style.brandingCenterX = CGFloat(Settings.brandingCenterX)
            style.brandingCenterY = CGFloat(Settings.brandingCenterY)
            style.brandingWidthFraction = CGFloat(Settings.brandingWidthFraction)
        }
        return style
    }

    /// Resolves the framed-mode background image (bundled, with a dev-path fallback).
    private func backgroundURL() -> URL? {
        let name = Settings.backgroundFile
        // Custom image stored as an absolute path.
        if name.hasPrefix("/"), FileManager.default.fileExists(atPath: name) {
            return URL(fileURLWithPath: name)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("background/\(name)"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    // MARK: - Alerts

    private func notifySaved(at url: URL) {
        let alert = NSAlert()
        alert.messageText = "Recording saved"
        alert.informativeText = url.path
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func presentPermissionHelp(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Open Screen Recording Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }
}
