import AppKit
import Carbon.HIToolbox

@available(macOS 12.3, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = RecordingEngine()
    private let countdown = CountdownController()
    private let hotKey = GlobalHotKey()

    private enum State { case idle, countdown, recording, rendering }
    private var state: State = .idle { didSet { refreshUI(); updateRecorderBarForState(); writeControlStatus() } }
    /// Absolute path of the most recent finished video, surfaced in the control status file.
    private var lastOutputPath: String?
    /// True while a recording was initiated by the external control surface — suppresses all
    /// DemoTape on-screen chrome (recorder bar, region border, teleprompter) for a clean capture.
    private var controlDriven = false

    private var recorderBar: RecorderBarController?
    private let renderHUD = RenderHUD()
    private var regionOverlay: RegionOverlay?
    private var webcamPreview: WebcamPreviewOverlay?
    /// Optional neural denoiser: active only if a Core ML model is bundled; otherwise the boosted
    /// on-device DSP reducer handles Smart Noise Suppression.
    private let speechEnhancer = CoreMLSpeechEnhancer()
    private var whileIdleItems: [NSMenuItem] = []
    private let aboutController = AboutController()
    private var welcomeController: WelcomeController?
    private weak var captionsMenuItem: NSMenuItem?
    private weak var voiceoverMenuItem: NSMenuItem?
    private weak var avatarMenuItem: NSMenuItem?
    private weak var briefMenuItem: NSMenuItem?
    private var aiBriefController: AIBriefActionController?
    private weak var selfRecordMenuItem: NSMenuItem?
    private var demoComposerController: DemoComposerController?
    private var avatarActionController: AvatarActionController?

    private lazy var startItem = NSMenuItem(
        title: "Start Recording  (⇧⌘S)", action: #selector(startRecording as () -> Void), keyEquivalent: "")
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
        startApp()
    }

    private func startApp() {
        installMainMenu()
        RecordingLayout.migrateFlatRecordings()   // group any older flat recordings into folders
        LaunchLocationGuard.check()   // warn if we're translocated / outside /Applications
        Notifier.shared.setup()   // ask for notification permission on first launch
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
        // System audio: native (SCK) capture, shown ONLY where the OS supports it (macOS 13+).
        // On older systems it's intentionally absent — system audio there goes through a loopback
        // device chosen in Audio Source, so we never show a toggle that can't be real.
        if SystemAudio.isSupported {
            let sysAudio = NSMenuItem(title: "Record System Audio",
                                      action: #selector(toggleSystemAudio), keyEquivalent: "")
            sysAudio.target = self
            sysAudio.state = Settings.captureSystemAudio ? .on : .off
            self.systemAudioItem = sysAudio
            inputMenu.addItem(sysAudio)
        }
        inputMenu.addItem(webcamItem)

        // Audio Source: pick which audio INPUT device the mic toggle records — a real mic, or a
        // loopback driver (BlackHole/Loopback) to capture system audio. Rebuilt on open.
        let audioSourceItem = NSMenuItem(title: "Audio Source", action: nil, keyEquivalent: "")
        let audioSourceMenu = NSMenu(); audioSourceMenu.autoenablesItems = false
        audioSourceMenu.delegate = self
        audioSourceItem.submenu = audioSourceMenu
        self.audioSourceMenu = audioSourceMenu
        inputMenu.addItem(audioSourceItem)
        inputMenu.addItem(.separator())
        // Smart noise suppression: a toggle that reveals a 0–100% strength slider.
        let noiseItem = NSMenuItem(title: "Smart Noise Suppression",
                                   action: #selector(toggleNoiseSuppression), keyEquivalent: "")
        noiseItem.target = self
        noiseItem.state = Settings.noiseSuppressionEnabled ? .on : .off
        self.noiseToggleItem = noiseItem
        inputMenu.addItem(noiseItem)
        let enhanceItem = NSMenuItem(title: "Enhance Voice",
                                     action: #selector(toggleEnhanceVoice), keyEquivalent: "")
        enhanceItem.target = self
        enhanceItem.state = Settings.enhanceVoiceEnabled ? .on : .off
        self.enhanceToggleItem = enhanceItem
        inputMenu.addItem(enhanceItem)
        inputMenu.addItem(.separator())
        inputMenu.addItem(webcamSettings)
        inputMenu.delegate = self
        self.inputMenu = inputMenu
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

        // --- Create with AI (generative — makes a new demo, not post-processing a take) ---
        let composeItem = NSMenuItem(title: "Create Demo with AI…",
                                     action: #selector(openDemoComposer), keyEquivalent: "")
        composeItem.target = self
        menu.addItem(composeItem)
        menu.addItem(.separator())

        // --- After recording (flat, in-order; AI steps are opt-in, enabled from AI Settings) ---
        menu.addItem(sectionHeader("After Recording"))

        let tightenItem = NSMenuItem(title: "Auto-Cut…",
                                     action: #selector(openTighten), keyEquivalent: "")
        tightenItem.target = self
        menu.addItem(tightenItem)

        let captionsItem = NSMenuItem(title: "Add Captions…",
                                      action: #selector(generateCaptions), keyEquivalent: "")
        captionsItem.target = self
        menu.addItem(captionsItem)

        let voiceoverItem = NSMenuItem(title: "Add Voiceover…",
                                       action: #selector(generateVoiceover), keyEquivalent: "")
        voiceoverItem.target = self
        menu.addItem(voiceoverItem)

        let avatarItem = NSMenuItem(title: "Generate Avatar…",
                                    action: #selector(generateAvatarPresenter), keyEquivalent: "")
        avatarItem.target = self
        menu.addItem(avatarItem)
        self.avatarMenuItem = avatarItem

        let briefItem = NSMenuItem(title: "Share Recording for AI…",
                                   action: #selector(explainToAI), keyEquivalent: "")
        briefItem.target = self
        menu.addItem(briefItem)
        self.briefMenuItem = briefItem

        let autoEditItem = NSMenuItem(title: "Auto-Edit…",
                                      action: #selector(openAutoEdit), keyEquivalent: "")
        autoEditItem.target = self
        menu.addItem(autoEditItem)

        menu.addItem(.separator())

        let publishItem = NSMenuItem(title: "Web Publish…",
                                     action: #selector(openWebPublish), keyEquivalent: "")
        publishItem.target = self
        menu.addItem(publishItem)

        // The AI actions (captions/voiceover/avatar/brief) enable only when configured in AI
        // Settings; the main menu's delegate re-gates them each time it opens.
        self.captionsMenuItem = captionsItem
        self.voiceoverMenuItem = voiceoverItem
        menu.delegate = self

        menu.addItem(.separator())

        // --- Utility ---
        let folderItem = NSMenuItem(title: "Recording Folder", action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let openFolder = NSMenuItem(title: "Open", action: #selector(openRecordingsFolder), keyEquivalent: "o")
        openFolder.target = self
        folderMenu.addItem(openFolder)
        let revealLatest = NSMenuItem(title: "Reveal Latest Export",
                                      action: #selector(revealLatestExport), keyEquivalent: "")
        revealLatest.target = self
        folderMenu.addItem(revealLatest)
        let changeDir = NSMenuItem(title: "Change Output Directory…",
                                   action: #selector(changeOutputDirectory), keyEquivalent: "")
        changeDir.target = self
        folderMenu.addItem(changeDir)
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)
        menu.addItem(.separator())

        // --- System Preferences (submenu of checkable toggles, like Input) ---
        let sysItem = NSMenuItem(title: "System Preferences", action: nil, keyEquivalent: "")
        let sysMenu = NSMenu(); sysMenu.autoenablesItems = false

        // AI Settings lives here — it's where captions / voiceover / avatar get their keys and are
        // enabled; the "After Recording" items above stay greyed until that's done.
        let aiSettings = NSMenuItem(title: "AI Settings…",
                                    action: #selector(openAISettings), keyEquivalent: "")
        aiSettings.target = self
        sysMenu.addItem(aiSettings)
        sysMenu.addItem(.separator())

        let loginToggle = NSMenuItem(title: "Launch DemoTape at Login",
                                     action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginToggle.target = self
        loginToggle.state = LoginItem.isEnabled ? .on : .off
        loginToggle.toolTip = "Open DemoTape automatically when you log in (it won't record until you press Start)."
        sysMenu.addItem(loginToggle)

        let dockToggle = NSMenuItem(title: "Show DemoTape in the Dock",
                                    action: #selector(toggleShowInDock), keyEquivalent: "")
        dockToggle.target = self
        dockToggle.state = Settings.showInDock ? .on : .off
        dockToggle.toolTip = "Run as a normal app with a Dock icon (instead of menu-bar only)."
        sysMenu.addItem(dockToggle)

        let autoZoomToggle = NSMenuItem(title: "Enable Auto-Zoom",
                                        action: #selector(toggleAutoZoom), keyEquivalent: "")
        autoZoomToggle.target = self
        autoZoomToggle.state = Settings.autoZoomEnabled ? .on : .off
        autoZoomToggle.toolTip = "Spring-physics zoom that follows your clicks and typing."
        sysMenu.addItem(autoZoomToggle)

        let selfRecordToggle = NSMenuItem(title: "Allow Recording DemoTape Itself",
                                          action: #selector(toggleAllowSelfRecording), keyEquivalent: "")
        selfRecordToggle.target = self
        selfRecordToggle.state = Settings.allowSelfRecording ? .on : .off
        selfRecordToggle.toolTip = "Keep DemoTape's menus and actions clickable while recording, so you "
            + "can record a walkthrough of DemoTape's own features. Off by default."
        sysMenu.addItem(selfRecordToggle)
        self.selfRecordMenuItem = selfRecordToggle

        sysItem.submenu = sysMenu
        menu.addItem(sysItem)

        let aboutItem = NSMenuItem(title: "About DemoTape",
                                   action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem(title: "Quit DemoTape",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Items disabled while a recording is in progress (disabling a submenu's parent
        // greys the whole submenu).
        whileIdleItems = [fullScreenItem, selectAreaItem, inputItem, backgroundItem,
                          teleprompterItem, brandingItem, composeItem, tightenItem,
                          captionsItem, voiceoverItem, avatarItem, briefItem, autoEditItem,
                          publishItem, changeDir]

        statusItem.menu = menu
        updateCaptureModeChecks()

        // Global ⇧⌘S toggles recording without touching the menu (so the click isn't
        // captured at the end of the video). Carbon consumes the key system-wide.
        hotKey.onPressed = { [weak self] in self?.toggleRecording() }
        hotKey.register(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))

        refreshUI()
        writeControlStatus()   // publish "idle" so the control surface is pollable from launch

        // Reflect the saved Dock preference (menu-bar-only by default).
        applyDockPreference(Settings.showInDock)

        // Launch with the recorder bar visible in full-screen mode, ready to go. Dismiss with ✕.
        Settings.useRegion = false
        updateCaptureModeChecks()
        presentRecorderBar()

        // Show the welcome for the first few launches, then only ~monthly (it becomes wallpaper
        // otherwise). Skip entirely once the user has everything granted and has seen it enough.
        if Settings.shouldShowWelcome {
            Settings.markWelcomeShown()
            let welcome = WelcomeController()
            welcomeController = welcome
            welcome.show(onFinish: { [weak self] in self?.welcomeController = nil })
        }
    }

    /// Menu-bar-only (accessory) apps have no application menu by default, so standard
    /// keyboard shortcuts like ⌘V/⌘C/⌘A never reach text fields in our windows. Installing
    /// a minimal main menu with an Edit menu restores Cut/Copy/Paste/Select All everywhere.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "About DemoTape", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let aiSettings = appMenu.addItem(withTitle: "AI Settings…", action: #selector(openAISettings), keyEquivalent: ",")
        aiSettings.target = self
        appMenu.addItem(.separator())
        let openFolder = appMenu.addItem(withTitle: "Open Recording Folder",
                                         action: #selector(openRecordingsFolder), keyEquivalent: "")
        openFolder.target = self
        let revealLatest = appMenu.addItem(withTitle: "Reveal Latest Export",
                                           action: #selector(revealLatestExport), keyEquivalent: "")
        revealLatest.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DemoTape", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
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
        // Grey out configuration/action items unless idle — except in "demo mode", where they stay
        // clickable during recording so you can film a walkthrough of DemoTape itself.
        let keepActive = (state == .idle) || (state == .recording && Settings.allowSelfRecording)
        whileIdleItems.forEach { $0.isEnabled = keepActive }

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

    @objc private func startRecording() { startRecording(countdownFrom: 3) }

    /// Shared start path. `count == 0` begins immediately (used by the external control surface for
    /// hands-off automation); otherwise it runs the usual 3-2-1 countdown.
    private func startRecording(countdownFrom count: Int) {
        guard state == .idle else { return }
        state = .countdown

        // Warm up the capture sessions concurrently with the countdown so recording
        // begins instantly at zero (no camera warm-up delay after "1").
        let prepareTask = Task { try await self.engine.prepare() }

        let begin: () -> Void = { [weak self] in
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

        if count > 0 { countdown.run(from: count) { begin() } }
        else { begin() }
    }

    // MARK: - External control surface (demotape:// URLs)

    /// Handles `demotape://record/{start,stop}` URLs so an external agent can drive a demo.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = DemoControl.parse(url) else { continue }
            Log.write("control: \(url.absoluteString)")
            DispatchQueue.main.async { [weak self] in self?.execute(command) }
        }
    }

    private func execute(_ command: DemoControl.Command) {
        switch command {
        case .cursor(let x, let y, let click):
            performControlCursor(x: x, y: y, click: click)
        case .stop:
            if state == .recording { stopRecording() }
        case .start(let opts):
            guard state == .idle else { Log.write("control: start ignored (busy)"); return }
            controlDriven = true
            dismissRecorderBar()   // no DemoTape chrome in an automated capture
            if let mic = opts.microphone {
                Settings.captureMicrophone = mic
                micItem.state = mic ? .on : .off
                recorderBar?.updateMic(mic)
            }
            if let cam = opts.webcam {
                Settings.captureWebcam = cam
                webcamItem.state = cam ? .on : .off
                recorderBar?.updateWebcam(cam)
            }
            applyControlRegion(opts.region)
            startRecording(countdownFrom: opts.countdown)
        }
    }

    /// Moves (and optionally clicks) the cursor from inside the running app. Because DemoTape
    /// holds the Accessibility grant and is the process doing the recording, the synthetic click
    /// is both delivered to the target app AND observed by our own global event monitor — so it
    /// lands in `events.json` and drives the auto-zoom. Coordinates are global screen pixels with
    /// a top-left origin (matching CoreGraphics display space), which is what the driver sends.
    private func performControlCursor(x: Double, y: Double, click: Bool) {
        let pt = CGPoint(x: x, y: y)
        CGWarpMouseCursorPosition(pt)
        CGAssociateMouseAndMouseCursorPosition(1)   // re-sync HW cursor after the warp
        guard click else { return }
        // Small settle so the move is visible before the click, mirroring a human motion.
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                              mouseCursorPosition: pt, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                            mouseCursorPosition: pt, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }

    /// Applies a control-surface region to the capture settings.
    private func applyControlRegion(_ region: DemoControl.Region) {
        switch region {
        case .fullScreen:
            Settings.useRegion = false
        case .normalized(let r):
            setRegionNormalized(r)
        case .pixels(let r):
            let b = CGDisplayBounds(CGMainDisplayID())
            if b.width > 0, b.height > 0 {
                setRegionNormalized(CGRect(x: r.minX / b.width, y: r.minY / b.height,
                                           width: r.width / b.width, height: r.height / b.height))
            } else {
                Settings.useRegion = false
            }
        }
        updateCaptureModeChecks()
        regionOverlay?.hide()   // automated capture shows no border
    }

    private func setRegionNormalized(_ r: CGRect) {
        let x = min(max(r.minX, 0), 0.95)
        let y = min(max(r.minY, 0), 0.95)
        Settings.regionX = Double(x)
        Settings.regionY = Double(y)
        Settings.regionW = Double(min(max(r.width, 0.05), 1 - x))
        Settings.regionH = Double(min(max(r.height, 0.05), 1 - y))
        Settings.regionPreset = "Freeform"   // freeform crop, no aspect lock or forced export size
        Settings.useRegion = true
    }

    /// Publishes the current state to `control.json` so an orchestrator can poll for progress.
    private func writeControlStatus() {
        let s: String
        switch state {
        case .idle: s = "idle"
        case .countdown: s = "countdown"
        case .recording: s = "recording"
        case .rendering: s = "rendering"
        }
        DemoControl.writeStatus(state: s, lastOutput: lastOutputPath)
    }

    @objc private func stopRecording() {
        guard state == .recording else { return }
        state = .rendering
        teleprompter.stop()
        dismissRecorderBar()   // close the bar + border; rendering starts
        Notifier.shared.renderStarted()   // "cooking your DemoTape…"
        renderHUD.show(stage: "Rendering your DemoTape…")   // visible progress for the auto-render
        Task {
            let raw = await engine.stop()
            guard let raw = raw else {
                await MainActor.run {
                    self.renderHUD.hide()
                    self.state = .idle
                    self.presentPermissionHelp(
                        title: "No video was captured",
                        message: "The recording was empty. This almost always means Screen Recording permission isn't granted yet.")
                }
                return
            }
            // Auto-produce the styled video (hands-off), reporting progress to the HUD.
            let camera = self.engine.lastCameraURL
            let style = await MainActor.run { self.makeStyle() }
            let styled = self.renderStyled(from: raw, camera: camera, style: style) { frac in
                DispatchQueue.main.async { self.renderHUD.setProgress(frac) }
            }
            // On-device audio cleanup: denoise, then enhance (studio voice). Both in place. These
            // stages don't report progress, so show a labeled spinner instead of a bar.
            if let styled = styled, Settings.captureMicrophone {
                if Settings.noiseSuppressionEnabled {
                    await MainActor.run { self.renderHUD.setIndeterminate(stage: "Cleaning up audio…") }
                    self.applyNoiseSuppression(to: styled)
                }
                if Settings.enhanceVoiceEnabled {
                    await MainActor.run { self.renderHUD.setIndeterminate(stage: "Enhancing voice…") }
                    self.applyVoiceEnhancement(to: styled)
                }
            }
            await MainActor.run {
                self.renderHUD.hide()
                self.lastOutputPath = (styled ?? raw).path   // published in control.json for agents
                let wasControlDriven = self.controlDriven
                self.controlDriven = false
                self.state = .idle
                self.notifySaved(at: styled ?? raw)
                if wasControlDriven { self.presentRecorderBar() }   // restore chrome for manual use
            }
        }
    }

    /// Denoises the mic audio of `url` in place (best-effort). Renders to a temp file and swaps it
    /// in only on success, so a failure never damages the recording.
    private func applyNoiseSuppression(to url: URL) {
        let temp = url.deletingPathExtension().appendingPathExtension("nr.mp4")
        // Use a bundled Core ML model if present, otherwise the boosted DSP reducer. Simple on/off.
        var stage = "DSP"
        do {
            if speechEnhancer.isAvailable {
                stage = "Core ML"
                try speechEnhancer.reduce(video: url, to: temp)
            } else {
                try NoiseReducer().reduce(video: url, strength: 0.9, to: temp)
            }
        } catch {
            Log.write("NoiseSuppression: \(stage) failed (\(error.localizedDescription)); using DSP")
            try? FileManager.default.removeItem(at: temp)
            stage = "DSP"
            do { try NoiseReducer().reduce(video: url, strength: 0.9, to: temp) }
            catch {
                try? FileManager.default.removeItem(at: temp)
                Log.write("NoiseReducer skipped: \(error.localizedDescription)")
                return
            }
        }
        // Swap the cleaned track in only on success.
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
            Log.write("NoiseSuppression: \(stage) cleaned \(url.lastPathComponent)")
        } catch {
            try? FileManager.default.removeItem(at: temp)
            Log.write("NoiseSuppression swap failed: \(error.localizedDescription)")
        }
    }

    /// Applies studio-voice enhancement to `url` in place (best-effort; failure leaves it intact).
    private func applyVoiceEnhancement(to url: URL) {
        let temp = url.deletingPathExtension().appendingPathExtension("ve.mp4")
        do {
            try VoiceEnhancer().enhance(video: url, to: temp)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
            Log.write("VoiceEnhancer: enhanced \(url.lastPathComponent)")
        } catch {
            try? FileManager.default.removeItem(at: temp)
            Log.write("VoiceEnhancer skipped: \(error.localizedDescription)")
        }
    }

    /// Renders the styled output next to the raw recording. Returns the styled URL,
    /// or nil if the sidecar/render failed (caller falls back to the raw file).
    private func renderStyled(from raw: URL, camera: URL?, style: VideoRenderer.Style,
                              progress: ((Double) -> Void)? = nil) -> URL? {
        let paths = SourcePaths(source: raw)
        let sidecar = paths.eventsURL                       // .source/<base>.events.json
        do {
            let data = try Data(contentsOf: sidecar)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(RecordingMetadata.self, from: data)
            let styled = paths.output(suffix: "styled")     // recording-folder root
            try VideoRenderer().render(videoURL: raw, metadata: metadata, cameraURL: camera,
                                       to: styled, style: style, progress: progress)
            return styled
        } catch {
            Log.write("renderStyled failed: \(error.localizedDescription)")
            return nil
        }
    }

    @objc private func openRecordingsFolder() {
        NSWorkspace.shared.open(Paths.outputDirectory)
    }

    /// Reveals the newest shareable output in Finder — the Web Publish bundle if one exists for the
    /// latest recording, otherwise the styled export (falling back to opening the folder).
    @objc private func revealLatestExport() {
        guard let latest = latestRecording() else {
            NSWorkspace.shared.open(Paths.outputDirectory); return
        }
        let root = SourcePaths(source: latest).recordingRoot
        let base = SourcePaths(source: latest).base
        let web = root.appendingPathComponent("\(base)-web", isDirectory: true)
        if FileManager.default.fileExists(atPath: web.path) {
            NSWorkspace.shared.activateFileViewerSelecting([web])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        }
    }

    @objc private func openAbout() {
        aboutController.show()
    }



    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let want = sender.state != .on
        if LoginItem.setEnabled(want) {
            sender.state = want ? .on : .off
        } else {
            // Reflect the real state and let the user know it couldn't be changed.
            sender.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Couldn't update the login item"
            let loginItemsPath: String
            if #available(macOS 13.0, *) {
                loginItemsPath = "System Settings → General → Login Items"
            } else {
                loginItemsPath = "System Preferences → Users & Groups → Login Items"
            }
            alert.informativeText = "macOS needs permission to manage login items. If a prompt to "
                + "control \u{201C}System Events\u{201D} appeared, click OK/Allow and try again — or add "
                + "DemoTape manually in \(loginItemsPath)."
            alert.runModal()
        }
    }

    @objc private func toggleShowInDock(_ sender: NSMenuItem) {
        let want = sender.state != .on
        sender.state = want ? .on : .off
        Settings.showInDock = want
        applyDockPreference(want)
    }

    @objc private func toggleAutoZoom(_ sender: NSMenuItem) {
        let want = sender.state != .on
        sender.state = want ? .on : .off
        Settings.autoZoomEnabled = want
    }

    @objc private func toggleAllowSelfRecording(_ sender: NSMenuItem) {
        let want = sender.state != .on
        sender.state = want ? .on : .off
        Settings.allowSelfRecording = want
        refreshUI()   // apply immediately if a recording is already in progress
    }

    /// Menu-bar-only apps use `.accessory`; `.regular` shows a Dock icon and app menu.
    /// Switching `.regular → .accessory` while the app is frontmost can leave the Dock tile
    /// behind, so we deactivate to force macOS to drop it. Dispatched so it runs after the
    /// current menu event settles.
    private func applyDockPreference(_ showInDock: Bool) {
        DispatchQueue.main.async {
            if showInDock {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }
        }
    }

    /// Enable the Generate actions only when their feature is on and a key is stored, so a
    /// user can have captions without voiceover (or vice versa).
    private func refreshAIMenuItems() {
        // A local STT server needs no key; hosted providers do.
        captionsMenuItem?.isEnabled = Settings.captionsEnabled
            && (Keychain.exists(account: Keychain.sttAPIKeyAccount) || Settings.sttKeyOptional)
        // ElevenLabs requires its key; local/custom TTS providers can run keyless.
        let ttsIsEleven = (Voiceover.TTSProvider(name: Settings.ttsProvider) == .elevenLabs)
        voiceoverMenuItem?.isEnabled = Settings.voiceoverEnabled
            && (!ttsIsEleven || Keychain.exists(account: Keychain.elevenAPIKeyAccount))
        // Avatar needs a HeyGen key and a latest voiceover (with its narration sidecar).
        avatarMenuItem?.isEnabled = Keychain.exists(account: Keychain.heygenAPIKeyAccount)
            && latestVoiceover() != nil
        // The AI brief uses the OpenAI-compatible key (same one captions use) for both the
        // transcription and the chat model.
        briefMenuItem?.isEnabled = Keychain.exists(account: Keychain.sttAPIKeyAccount)
    }

    /// Newest `…voiceover.mp4` whose narration sidecar still exists, across per-recording folders.
    private func latestVoiceover() -> URL? {
        RecordingLayout.latestFinal(suffix: ".voiceover.mp4") { url in
            FileManager.default.fileExists(
                atPath: url.deletingPathExtension().appendingPathExtension("narration.m4a").path)
        }
    }

    @objc private func generateAvatarPresenter() {
        guard let key = Keychain.get(account: Keychain.heygenAPIKeyAccount), !key.isEmpty else {
            let a = NSAlert()
            a.messageText = "Add a HeyGen key first"
            a.informativeText = "Avatar Presenter uses HeyGen (bring-your-own-key). Add it in AI Settings."
            a.addButton(withTitle: "Open AI Settings…"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { openAISettings() }
            return
        }
        guard let voiceover = latestVoiceover() else {
            presentPermissionHelp(title: "No voiceover found",
                                  message: "Generate an ElevenLabs voiceover first — the avatar is lip-synced to it.")
            return
        }
        // narration sidecar: <base>.voiceover.mp4 → <base>.voiceover.narration.m4a
        let narration = voiceover.deletingPathExtension().appendingPathExtension("narration.m4a")
        guard FileManager.default.fileExists(atPath: narration.path) else {
            presentPermissionHelp(title: "Narration missing",
                                  message: "Re-generate the voiceover — its narration audio is needed for the avatar.")
            return
        }
        let controller = AvatarActionController(source: voiceover, apiKey: key,
                                                voiceGender: Settings.elevenVoiceGender)
        avatarActionController = controller
        controller.show(onClose: { [weak self] in self?.avatarActionController = nil })
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

    private var autoCutController: AutoCutActionController?
    @objc private func openTighten() {
        guard let video = latestRecording() else {
            presentPermissionHelp(title: "No recording found",
                                  message: "Record something first — this trims/speeds up your latest recording.")
            return
        }
        let controller = AutoCutActionController(source: video)
        autoCutController = controller  // retain while open
        controller.show(onClose: { [weak self] in self?.autoCutController = nil })
    }

    // MARK: - Captions (AI, bring-your-own-key)

    /// Newest playable recording (prefers the styled export), across per-recording folders.
    private func latestRecording() -> URL? { RecordingLayout.latestRecording() }

    private var voiceoverActionController: VoiceoverActionController?
    @objc private func generateVoiceover() {
        // ElevenLabs needs a stored key; local/custom providers may run keyless, so only require
        // the feature to be enabled there.
        let isEleven = (Voiceover.TTSProvider(name: Settings.ttsProvider) == .elevenLabs)
        let key = Keychain.get(account: Keychain.elevenAPIKeyAccount) ?? ""
        let ready = Settings.voiceoverEnabled && (!isEleven || !key.isEmpty)
        guard ready else {
            let alert = NSAlert()
            alert.messageText = "Enable voiceover first"
            alert.informativeText = isEleven
                ? (Keychain.exists(account: Keychain.elevenAPIKeyAccount)
                    ? "Turn on Voiceover in AI Settings to generate narration."
                    : "Voiceover uses ElevenLabs text-to-speech. Add and test your ElevenLabs key in "
                        + "AI Settings, enable Voiceover, then try again.")
                : "Turn on Voiceover in AI Settings and set your local TTS server's Base URL, then try again."
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
        let controller = VoiceoverActionController(source: video, apiKey: key)
        voiceoverActionController = controller  // retain while open
        controller.show(onClose: { [weak self] in self?.voiceoverActionController = nil })
    }

    private var autoEditController: AutoEditActionController?
    @objc private func openAutoEdit() {
        guard let video = latestRecording() else {
            presentPermissionHelp(title: "No recording found",
                                  message: "Record something first — Auto-Edit re-edits your latest recording.")
            return
        }
        let controller = AutoEditActionController(source: video)
        autoEditController = controller  // retain while open
        controller.show(onClose: { [weak self] in self?.autoEditController = nil })
    }

    private var aiSettingsController: AISettingsController?
    @objc private func openAISettings() {
        let controller = AISettingsController()
        aiSettingsController = controller  // retain while open
        controller.show()
    }

    private var captionsActionController: CaptionsActionController?
    @objc private func generateCaptions() {
        guard let video = latestRecording() else {
            presentPermissionHelp(title: "No recording found",
                                  message: "Record something first — captions run on your latest recording.")
            return
        }
        // Reuse a cached transcript if present (no API call needed to open the window).
        let cached = Captions.loadTranscript(for: video)
        let key = Keychain.get(account: Keychain.sttAPIKeyAccount) ?? ""

        // Need either a cached transcript, or the feature enabled with a usable endpoint. A local
        // (localhost) STT server is usable without a key; hosted providers require one.
        let endpointReady = !key.isEmpty || Settings.sttKeyOptional
        if (cached?.isEmpty ?? true) && !(Settings.captionsEnabled && endpointReady) {
            let alert = NSAlert()
            alert.messageText = "Enable captions first"
            alert.informativeText = (Keychain.exists(account: Keychain.sttAPIKeyAccount) || Settings.sttKeyOptional)
                ? "Turn on Captions in AI Settings to transcribe this recording."
                : "Captions use an OpenAI-compatible speech-to-text API. Add and test your key in "
                    + "AI Settings (or point at a local server), enable Captions, then try again."
            alert.addButton(withTitle: "Open AI Settings…")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { openAISettings() }
            return
        }

        let config = Captions.Config(baseURL: Settings.sttBaseURL, model: Settings.sttModel,
                                     apiKey: key, language: Settings.sttLanguage)
        let controller = CaptionsActionController(source: video, cachedCues: cached, config: config)
        captionsActionController = controller
        controller.show(onClose: { [weak self] in self?.captionsActionController = nil })
    }

    @objc private func openDemoComposer() {
        let controller = DemoComposerController()
        demoComposerController = controller
        controller.show(onClose: { [weak self] in self?.demoComposerController = nil })
    }

    @objc private func explainToAI() {
        guard let video = latestRecording() else {
            presentPermissionHelp(title: "No recording found",
                                  message: "Record a short walkthrough first — the AI brief runs on your latest recording.")
            return
        }
        let key = Keychain.get(account: Keychain.sttAPIKeyAccount) ?? ""
        guard !key.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Add your AI key first"
            alert.informativeText = "The AI brief uses an OpenAI-compatible key (the same one captions use) to "
                + "transcribe and analyze your recording. Add and test your key in AI Settings, then try again."
            alert.addButton(withTitle: "Open AI Settings…")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { openAISettings() }
            return
        }
        let stt = Captions.Config(baseURL: Settings.sttBaseURL, model: Settings.sttModel,
                                  apiKey: key, language: Settings.sttLanguage)
        let chat = AIBrief.Config(baseURL: Settings.sttBaseURL, model: Settings.aiDirectorModel, apiKey: key)
        let controller = AIBriefActionController(source: video, stt: stt, chat: chat)
        aiBriefController = controller
        controller.show(onClose: { [weak self] in self?.aiBriefController = nil })
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
        refreshWebcamPreview()
    }

    private var webcamSettingsController: WebcamSettingsController?
    @objc private func openWebcamSettings() {
        let controller = WebcamSettingsController()
        webcamSettingsController = controller // retain while open
        controller.show()
    }

    // MARK: - Smart noise suppression (menu control)

    private var inputMenu: NSMenu?
    private var audioSourceMenu: NSMenu?
    private weak var systemAudioItem: NSMenuItem?
    private var noiseToggleItem: NSMenuItem?
    private var enhanceToggleItem: NSMenuItem?

    @objc private func toggleNoiseSuppression() {
        Settings.noiseSuppressionEnabled.toggle()
        noiseToggleItem?.state = Settings.noiseSuppressionEnabled ? .on : .off
    }

    @objc private func toggleEnhanceVoice() {
        Settings.enhanceVoiceEnabled.toggle()
        enhanceToggleItem?.state = Settings.enhanceVoiceEnabled ? .on : .off
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
                    self?.webcamPreview?.show(in: screenRect)   // keep the bubble anchored in-region
                }
                regionOverlay = overlay
            }
            regionOverlay?.aspect = AreaPreset.named(Settings.regionPreset).aspect
            regionOverlay?.show(region: region, editable: true)  // adjustable until recording
        } else {
            regionOverlay?.hide()
        }
        recorderBar?.show(anchorRegion: region,
                          micOn: Settings.captureMicrophone, webcamOn: Settings.captureWebcam)
        refreshWebcamPreview()
    }

    /// Shows/hides the live camera bubble anchored in the recording area while preparing. Hidden
    /// during recording so it's never captured (the webcam is composited in afterward).
    private func refreshWebcamPreview() {
        guard state == .idle, recorderBar != nil, Settings.captureWebcam else {
            webcamPreview?.hide(); return
        }
        if webcamPreview == nil { webcamPreview = WebcamPreviewOverlay() }
        webcamPreview?.show(in: regionScreenRect())
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
        webcamPreview?.hide()
    }

    /// Keep the floating bar/border in sync with the recording state. For full-screen
    /// capture the bar is hidden during recording (it would otherwise be in the video);
    /// for region capture it stays put, outside the recorded area.
    private func updateRecorderBarForState() {
        if controlDriven {   // keep the screen clean for automated captures
            dismissRecorderBar()
            teleprompter.stop()
            return
        }
        guard recorderBar != nil else { return }
        switch state {
        case .countdown:
            // Lock the region (click-through border only) once we're about to record.
            regionOverlay?.setEditable(false)
            webcamPreview?.hide()   // never let the live bubble land in the capture
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
        // Auto-zoom off → hold the camera at 1× (no click/typing zoom).
        if !Settings.autoZoomEnabled { style.maxZoom = 1.0 }
        style.useBackground = Settings.useRegion && Settings.framedBackground
        if style.useBackground {
            style.backgroundImageURL = backgroundURL()
        }
        if Settings.useRegion, let target = AreaPreset.named(Settings.regionPreset).targetSize {
            style.exportSize = target   // scale the export to the preset's target resolution
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
        // Prefer a native notification with a Reveal action; fall back to an alert if
        // notifications aren't authorized.
        if Notifier.shared.renderFinished(url: url) { return }
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

@available(macOS 12.3, *)
extension AppDelegate: NSMenuDelegate {
    // Refresh the AI action items right before the submenu opens, reflecting the latest
    // per-feature settings and stored keys.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === inputMenu {
            noiseToggleItem?.state = Settings.noiseSuppressionEnabled ? .on : .off
            enhanceToggleItem?.state = Settings.enhanceVoiceEnabled ? .on : .off
            systemAudioItem?.state = Settings.captureSystemAudio ? .on : .off
            return
        }
        if menu === audioSourceMenu {
            rebuildAudioSourceMenu(menu)
            return
        }
        refreshAIMenuItems()
    }

    /// Rebuilds the Audio Source list each time it opens: "System Default" plus every connected
    /// audio input device, with a checkmark on the current choice. Loopback drivers are labelled
    /// so users recording system audio can spot them; if none is installed, a hint links to setup.
    private func rebuildAudioSourceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let selectedID = Settings.audioInputDeviceID

        let defaultItem = NSMenuItem(title: "System Default", action: #selector(selectAudioSource(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = ""
        defaultItem.state = selectedID.isEmpty ? .on : .off
        menu.addItem(defaultItem)
        menu.addItem(.separator())

        let devices = AudioDevices.inputs()
        if devices.isEmpty {
            let none = NSMenuItem(title: "No audio inputs found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for device in devices {
            let label = AudioDevices.looksLikeLoopback(device)
                ? "\(device.localizedName)  (system audio)" : device.localizedName
            let item = NSMenuItem(title: label, action: #selector(selectAudioSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = (device.uniqueID == selectedID) ? .on : .off
            menu.addItem(item)
        }

    }

    @objc private func toggleSystemAudio() {
        Settings.captureSystemAudio.toggle()
        systemAudioItem?.state = Settings.captureSystemAudio ? .on : .off
    }

    @objc private func selectAudioSource(_ sender: NSMenuItem) {
        Settings.audioInputDeviceID = (sender.representedObject as? String) ?? ""
        // Recording the loopback device requires the mic path to be on.
        if !Settings.audioInputDeviceID.isEmpty, !Settings.captureMicrophone {
            Settings.captureMicrophone = true
            micItem.state = .on
            recorderBar?.updateMic(true)
        }
    }

}
