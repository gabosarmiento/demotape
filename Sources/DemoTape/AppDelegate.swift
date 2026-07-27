import AppKit
import Carbon.HIToolbox
import CoreGraphics
import AVFoundation

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

    func applicationDidBecomeActive(_ notification: Notification) {
        // Pick up a notification-permission change the user made in System Settings while running.
        Notifier.shared.refreshAuthorization()
    }

    /// Clicking the Dock icon (or reopening) when nothing is on screen must DO something. DemoTape is
    /// a menu-bar app, but it shows a Dock icon whenever a window is open, so a user naturally clicks
    /// it — and with no window and the menu bar easy to miss, it felt dead. Show the recorder bar, the
    /// same thing choosing a capture mode does, so there's always a visible way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        if recorderBar?.isRecording == true { return true }   // don't disturb an active recording
        selectFullScreen()   // presents the recorder bar in full-screen capture mode
        return true
    }

    private func startApp() {
        // Keep the mic toggle honest: if it was left "on" but macOS doesn't grant mic access, show
        // it off until the user re-enables it (which re-requests permission).
        if Settings.captureMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            Settings.captureMicrophone = false
        }
        // Same for the webcam: don't show it "on" at launch if macOS doesn't grant camera access.
        if Settings.captureWebcam && AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            Settings.captureWebcam = false
        }
        installMainMenu()
        RecordingLayout.migrateFlatRecordings()   // group any older flat recordings into folders
        RecordingLayout.sweepOrphanedTempFiles()   // delete leftover *.sb-* atomic-write temps
        LaunchLocationGuard.check()   // warn if we're translocated / outside /Applications
        Notifier.shared.setup()   // ask for notification permission on first launch
        // (Screen Recording registration/guidance is handled by the Welcome window below and by
        // the record flow — we don't fire the system prompt at launch, so it can't get hidden
        // behind the Welcome window.)
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
        //
        // Two ways to get a video, side by side, because that is what they are: press Start and record
        // it yourself, or hand the whole job to a coding agent. The agent path used to sit five
        // sections down as "Create Demo with AI…", where it read as one more AI toggle next to
        // Captions and Voiceover — when in fact it's a different actor doing the work: the agent reads
        // the codebase, scripts the scenes, drives the app, and verifies each scene before handing the
        // video back. Naming the actor is the whole point of the label.
        startItem.target = self
        stopItem.target = self
        menu.addItem(startItem)
        menu.addItem(stopItem)

        let composeItem = NSMenuItem(title: "Let Your Coding Agent Record a Demo…",
                                     action: #selector(openDemoComposer), keyEquivalent: "")
        composeItem.target = self
        composeItem.image = NSImage(systemSymbolName: "sparkles.rectangle.stack",
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        menu.addItem(composeItem)
        menu.addItem(.separator())

        // --- Capture mode ---
        menu.addItem(sectionHeader("Capture"))
        fullScreenItem.target = self
        menu.addItem(fullScreenItem)
        selectAreaItem.target = self
        menu.addItem(selectAreaItem)
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Setup"))

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
        self.inputSubmenu = inputMenu       // the recorder bar's popover drops this same submenu
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

        // --- After recording (trim/re-edit first, then the content-adding AI steps, in the
        // order you'd normally apply them; AI steps are opt-in, enabled from AI Settings) ---
        menu.addItem(sectionHeader("After Recording"))

        let tightenItem = NSMenuItem(title: "Auto-Cut…",
                                     action: #selector(openTighten), keyEquivalent: "")
        tightenItem.target = self
        menu.addItem(tightenItem)

        let autoEditItem = NSMenuItem(title: "Auto-Edit…",
                                      action: #selector(openAutoEdit), keyEquivalent: "")
        autoEditItem.target = self
        menu.addItem(autoEditItem)

        menu.addItem(.separator())

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

        // --- AI handoff (a different job from the polish steps above: turns the recording into
        // a structured bug report/brief for a coding agent, not a step toward a finished video) ---
        let briefItem = NSMenuItem(title: "Share Recording for AI…",
                                   action: #selector(explainToAI), keyEquivalent: "")
        briefItem.target = self
        menu.addItem(briefItem)
        self.briefMenuItem = briefItem

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

        // DemoTape is free — a star is the only ask, so keep it one click away.
        let starItem = NSMenuItem(title: "Star DemoTape on GitHub",
                                  action: #selector(starRepo), keyEquivalent: "")
        starItem.target = self
        menu.addItem(starItem)

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

        // Show the welcome for the first few launches, then only ~monthly — BUT always show it when
        // the required Screen Recording permission is missing, so a new install (or one whose grant
        // was invalidated by a signature change) is guided to grant it instead of silently not
        // working. The welcome only surfaces still-missing permissions and disappears once granted.
        let needsRequiredPermission = !CGPreflightScreenCaptureAccess()
        if Settings.shouldShowWelcome || needsRequiredPermission {
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
        case .cursor(let x, let y, let click, let glideMs):
            // Run cursor work on a SERIAL BACKGROUND queue, never the main thread. An animated
            // glide sleeps for its whole duration; doing that on main blocks the run loop, so
            // further demotape:// URLs pile up and then execute in one burst (observed: four
            // clicks landing on the same video frame). A serial queue keeps them strictly ordered
            // while leaving the main thread free to keep receiving them.
            cursorQueue.async { [weak self] in
                self?.performControlCursor(x: x, y: y, click: click, glideMs: glideMs)
            }
        case .type(let text, let cps, let expectedApp):
            // Serialised with cursor work so a click-then-type sequence can't interleave.
            cursorQueue.async { [weak self] in
                self?.performControlTyping(text: text, cps: cps, expectedApp: expectedApp)
            }
        case .typingActivity(let chars, let cps, let caret):
            engine.noteTypingActivity(characters: chars, charsPerSecond: cps > 0 ? cps : 14,
                                      caret: caret)
        case .cursorPath(let points, let ms):
            cursorQueue.async { [weak self] in
                self?.sweepCursor(along: points, duration: Double(ms) / 1000.0)
            }
        case .openUI(let window, let holdMs):
            openControlWindow(window, holdMs: holdMs)
        case .dumpUI(let app):
            UIQuery.writeDump(app: app)
        case .element(let query, let click):
            resolveAndAct(query: query, click: click)
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

    /// Opens one of our own windows on request, so a walkthrough of DemoTape itself can be scripted
    /// without an orchestrator having to guess where menu rows are on screen.
    private func openControlWindow(_ window: DemoControl.Window, holdMs: Int = 0) {
        Log.write("control: open window \(window.rawValue)")
        switch window {
        case .about: openAbout()
        case .publish: openWebPublish()
        case .composer: openDemoComposer()
        case .settings: openAISettings()
        case .voiceover: generateVoiceover()
        case .captions: generateCaptions()
        case .welcome:
            let welcome = WelcomeController()
            welcomeController = welcome
            welcome.show(onFinish: { [weak self] in self?.welcomeController = nil })
        case .menu:
            // Drop our own menu open — deterministic, and it makes the menu appear exactly where a
            // real user's click would put it, which is what a walkthrough needs to film.
            //
            // Schedule the dismissal BEFORE opening, because performClick blocks in NSMenu's
            // tracking loop until the menu closes. The timer must be registered in `.common` modes:
            // a default-mode timer (or DispatchQueue.main.asyncAfter) never fires during menu
            // tracking, which would leave the menu open forever and stall every later command.
            if holdMs > 0 {
                let timer = Timer(timeInterval: Double(holdMs) / 1000.0, repeats: false) { [weak self] _ in
                    self?.statusItem.menu?.cancelTracking()
                    Log.write("menu: auto-dismissed after \(holdMs)ms")
                }
                RunLoop.main.add(timer, forMode: .common)
            }
            statusItem.button?.performClick(nil)
            return
        }
        // Give AppKit a beat to lay the window out, then publish where it landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.publishControlWindowFrame()
        }
    }

    /// Serialises cursor commands off the main thread so an animated glide can't stall URL handling.
    private let cursorQueue = DispatchQueue(label: "dev.demotape.cursor")

    /// Looks a target up in the live UI and (optionally) clicks it. The resolved rect is published
    /// to control.json either way, and a miss is logged with `found: false` rather than silently
    /// clicking somewhere arbitrary — a demo should fail loudly, not record a lie.
    private func resolveAndAct(query: UIQuery.Query, click: Bool) {
        guard let element = UIQuery.find(query) else {
            Log.write("UIQuery: no match for '\(query.label)'"
                      + (query.role.map { " role=\($0)" } ?? "")
                      + " in \(query.app ?? "DemoTape")")
            lastControlElement = nil
            publishElementStatus(found: false, label: query.label)
            return
        }
        Log.write("UIQuery: '\(query.label)' -> \(element.role) '\(element.label)' "
                  + "at \(Int(element.centre.x)),\(Int(element.centre.y))")
        lastControlElement = element
        publishElementStatus(found: true, label: element.label)
        guard click else { return }
        let point = element.centre
        cursorQueue.async { [weak self] in
            // Travel scaled to distance, so near targets don't crawl and far ones don't teleport.
            self?.performControlCursor(x: point.x, y: point.y, click: true, glideMs: 520)
        }
    }

    private var lastControlElement: UIQuery.Element?

    private func publishElementStatus(found: Bool, label: String) {
        DemoControl.writeStatus(state: state == .recording ? "recording" : "idle",
                                lastOutput: lastOutputPath,
                                menuBarButton: menuBarButtonFrame(),
                                window: lastControlWindowFrame,
                                element: lastControlElement.map {
                                    DemoControl.ElementStatus(role: $0.role, label: $0.label,
                                                              frame: $0.frame, found: found)
                                } ?? DemoControl.ElementStatus(role: "", label: label,
                                                               frame: .zero, found: false))
    }

    /// Moves (and optionally clicks) the cursor from inside the running app. Because DemoTape
    /// holds the Accessibility grant and is the process doing the recording, the synthetic click
    /// is both delivered to the target app AND observed by our own global event monitor — so it
    /// lands in `events.json` and drives the auto-zoom. Coordinates are global screen pixels with
    /// a top-left origin (matching CoreGraphics display space), which is what the driver sends.
    private func performControlCursor(x: Double, y: Double, click: Bool, glideMs: Int = 0) {
        let pt = CGPoint(x: x, y: y)
        if glideMs > 0 {
            glideCursor(to: pt, duration: Double(glideMs) / 1000.0)
        } else {
            CGWarpMouseCursorPosition(pt)
            CGAssociateMouseAndMouseCursorPosition(1)   // re-sync HW cursor after the warp
        }
        guard click else { return }
        // Beat between arriving and clicking — a human lands, aims, then presses.
        Thread.sleep(forTimeInterval: 0.12)
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                              mouseCursorPosition: pt, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        // Real presses have dwell; an instant down/up can also be swallowed by some controls.
        Thread.sleep(forTimeInterval: 0.06)
        if let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                            mouseCursorPosition: pt, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }

    /// Types text as real OS keystrokes into whatever is focused.
    ///
    /// Two reasons this lives in the app rather than in the driver. Posting key events needs the
    /// Accessibility grant, which the installed app has and a shell-launched tool does not. And
    /// auto-zoom is driven by clicks *and keys* (`FocusTimeline`), so keystrokes our own global
    /// monitor can't see leave the camera wide open while text appears — which is exactly what
    /// happened with browser-level synthetic typing.
    ///
    /// Rhythm is deliberately uneven, for the same reason the cursor glides rather than warps: a
    /// metronome reads as a machine. Sentence punctuation gets a longer beat than letters.
    private func performControlTyping(text: String, cps: Double, expectedApp: String?) {
        // Refuse to type unless the caller's expected app is frontmost. Keystrokes follow system
        // focus, so without this check a mis-timed command types into whatever the user is actually
        // using — an editor, a terminal — which is both destructive and silent, because the keys are
        // still recorded as if it worked.
        if let expected = expectedApp?.trimmingCharacters(in: .whitespaces), !expected.isEmpty {
            let front = NSWorkspace.shared.frontmostApplication
            let name = front?.localizedName ?? ""
            let bundle = front?.bundleIdentifier ?? ""
            let matches = name.localizedCaseInsensitiveContains(expected)
                || bundle.localizedCaseInsensitiveContains(expected)
            guard matches else {
                Log.write("control: REFUSED typing — expected '\(expected)' frontmost, but '\(name)' is. "
                          + "Nothing was typed.")
                return
            }
        }
        let perChar = 1.0 / max(4.0, cps > 0 ? cps : 14.0)   // default ≈14 chars/s
        let source = CGEventSource(stateID: .hidSystemState)
        Log.write("control: typing \(text.count) chars at \(String(format: "%.1f", 1 / perChar))/s")
        for ch in text {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            var utf16 = Array(String(ch).utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

            var delay = perChar * Double.random(in: 0.6...1.5)
            if ".?!".contains(ch) { delay += perChar * 6 }
            else if ",;:".contains(ch) { delay += perChar * 3 }
            else if ch == " " && Double.random(in: 0...1) < 0.08 { delay += perChar * 4 }
            Thread.sleep(forTimeInterval: delay)
        }
    }

    /// Animates the cursor from where it is to `target` so the recording reads as a hand, not a
    /// teleport. Three things make it feel human:
    ///
    /// - **Ease-in-out** — accelerate away, decelerate onto the target, rather than constant speed.
    /// - **A slight arc** — real pointer paths bow; a dead-straight line looks machine-driven. The
    ///   bow is perpendicular to the travel and scales with distance, so short hops stay direct.
    /// - **Overshoot and settle** — long moves drift just past the target and come back, the way a
    ///   hand does when it commits fast and corrects.
    ///
    /// Runs synchronously on the calling (main) thread: the control URLs are sequential by design,
    /// so a script's next instruction shouldn't start mid-glide.
    private func glideCursor(to target: CGPoint, duration: Double) {
        let start = currentCursorPoint()
        let dx = target.x - start.x, dy = target.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 1 else {
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)
            return
        }

        let frameRate = 60.0
        let steps = max(2, Int((duration * frameRate).rounded()))
        // Bow the path perpendicular to travel, capped so long trips don't swing wildly. The amount
        // AND the side vary per move: a hand doesn't curve the same way twice, and a fixed bow makes
        // repeated travels between the same two points look stamped from a template.
        let bowSide: CGFloat = Bool.random() ? 1 : -1
        let bow = min(distance * CGFloat.random(in: 0.035...0.075), 38.0) * bowSide
        let nx = -dy / distance, ny = dx / distance
        // Only long moves get an overshoot; short nudges land clean.
        let overshoot = distance > 220 ? min(distance * CGFloat.random(in: 0.008...0.016), 9.0) : 0

        // Vary the acceleration curve per move. A fixed easing exponent is subtle but consistent,
        // and consistency across dozens of moves is what reads as mechanical.
        let curve = Double.random(in: 1.7...2.4)
        // A slow tremor across the path, so even the straight part of a glide isn't perfectly clean.
        let tremor = CGFloat.random(in: 0.6...1.8)
        let tremorPhase = Double.random(in: 0...(2 * .pi))

        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = t < 0.5
                ? pow(2 * t, curve) / 2
                : 1 - pow(-2 * t + 2, curve) / 2   // easeInOut with a per-move exponent
            // sin() peaks mid-flight and returns to zero at both ends, so the arc never
            // displaces the start or the target.
            let arc = sin(eased * .pi) * bow
            // Ramps in quadratically so the drift past the target only appears at the end.
            let push = eased * eased * overshoot
            // Tremor fades out towards the target, so the landing is still precise.
            let wobble = sin(eased * 6 * .pi + tremorPhase) * tremor * CGFloat(1 - eased)
            let p = CGPoint(x: start.x + dx * eased + nx * (arc + wobble) + (dx / distance) * push,
                            y: start.y + dy * eased + ny * (arc + wobble) + (dy / distance) * push)
            CGWarpMouseCursorPosition(p)
            Thread.sleep(forTimeInterval: duration / Double(steps))
        }

        if overshoot > 0 {
            // Settle back onto the target from the overshoot.
            let settleSteps = 6
            let from = CGPoint(x: target.x + (dx / distance) * overshoot,
                               y: target.y + (dy / distance) * overshoot)
            for i in 1...settleSteps {
                let t = Double(i) / Double(settleSteps)
                let p = CGPoint(x: from.x + (target.x - from.x) * t,
                                y: from.y + (target.y - from.y) * t)
                CGWarpMouseCursorPosition(p)
                Thread.sleep(forTimeInterval: 0.012)
            }
        }
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Sweeps the cursor along a path as one continuous motion.
    ///
    /// Attention gestures used to be issued as a series of short moves, and every seam showed — the
    /// cursor stuttered around a circle instead of drawing it. Here the whole shape arrives at once,
    /// so it can be treated as a single animation: a Catmull-Rom spline through the given points
    /// (which rounds the corners a hand would round anyway), sampled at frame rate, with the speed
    /// eased in and out over the WHOLE gesture rather than per segment.
    private func sweepCursor(along points: [CGPoint], duration: Double) {
        guard points.count >= 2, duration > 0 else { return }
        // Start from where the cursor actually is, so the gesture doesn't jump to begin.
        var control = [currentCursorPoint()] + points
        // Duplicate the endpoints: Catmull-Rom needs a neighbour on each side to define the tangent.
        control.insert(control[0], at: 0)
        control.append(control[control.count - 1])

        let steps = max(8, Int(duration * 60))
        let segments = control.count - 3
        for i in 1...steps {
            let progress = Double(i) / Double(steps)
            // Ease the whole sweep, not each leg — that's what made it feel mechanical.
            let eased = progress < 0.5
                ? 2 * progress * progress
                : 1 - pow(-2 * progress + 2, 2) / 2
            let scaled = eased * Double(segments)
            let index = min(segments - 1, Int(scaled))
            let t = CGFloat(scaled - Double(index))
            let p = catmullRom(control[index], control[index + 1],
                               control[index + 2], control[index + 3], t: t)
            CGWarpMouseCursorPosition(p)
            Thread.sleep(forTimeInterval: duration / Double(steps))
        }
        CGWarpMouseCursorPosition(points[points.count - 1])
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Catmull-Rom interpolation: passes through p1 and p2, using p0/p3 for the tangents. Chosen over
    /// Bézier because the caller supplies points the cursor must actually visit.
    private func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                            t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y))
    }

    /// Current cursor position in top-left-origin screen points (CoreGraphics space), matching what
    /// the control surface accepts. `NSEvent.mouseLocation` is bottom-left, so it needs flipping.
    /// Uses CGDisplayBounds rather than NSScreen because this now runs on a background queue, and
    /// CoreGraphics display queries are safe there while AppKit's screen list is not.
    private func currentCursorPoint() -> CGPoint {
        let p = NSEvent.mouseLocation
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: p.x, y: height - p.y)
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
        DemoControl.writeStatus(state: s, lastOutput: lastOutputPath,
                                menuBarButton: menuBarButtonFrame(),
                                window: lastControlWindowFrame)
    }

    /// Screen rect (top-left origin) of the window most recently opened via `ui/open`.
    private var lastControlWindowFrame: CGRect?

    /// Records the frontmost window's rect after a `ui/open`, then republishes status so a script
    /// can read it and aim at inert parts of the window.
    private func publishControlWindowFrame() {
        // Prefer the key window; fall back to a visible TITLED window. The plain
        // `isVisible && canBecomeKey` test picked up the borderless recorder bar panel instead.
        let candidate = NSApp.keyWindow ?? NSApp.orderedWindows.first {
            $0.isVisible && $0.styleMask.contains(.titled)
        }
        guard let win = candidate, win.styleMask.contains(.titled),
              let screen = NSScreen.screens.first else { return }
        let f = win.frame   // bottom-left origin
        lastControlWindowFrame = CGRect(x: f.minX, y: screen.frame.height - f.maxY,
                                        width: f.width, height: f.height)
        DemoControl.writeStatus(state: state == .recording ? "recording" : "idle",
                                lastOutput: lastOutputPath,
                                menuBarButton: menuBarButtonFrame(),
                                window: lastControlWindowFrame)
    }

    /// Screen rect of our menu-bar icon, converted to top-left origin points (CoreGraphics space)
    /// so it matches the coordinates `demotape://cursor` expects. Published in control.json so a
    /// walkthrough of DemoTape itself can click its own menu.
    private func menuBarButtonFrame() -> CGRect? {
        guard let window = statusItem.button?.window else { return nil }
        let f = window.frame   // bottom-left origin; horizontally reliable
        // Vertically, a status item's window lives in its own space above NSScreen.frame, so
        // converting its maxY yields a negative (off-screen) value. The icon is always inside the
        // menu bar, which occupies the top `thickness` points of the screen — use that instead.
        let barHeight = NSStatusBar.system.thickness
        guard f.width > 0, f.minX > 0 else { return nil }   // not laid out yet
        return CGRect(x: f.minX, y: 0, width: f.width, height: barHeight)
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
            // Save the recipe that produced this video. Without it a later `--render` would fall
            // back to defaults (or, worse, whatever the settings happen to be then), so the look
            // couldn't be reproduced or revised one field at a time.
            let recipeURL = paths.recordingRoot.appendingPathComponent(RenderRecipe.filename)
            do {
                try RenderRecipe.capture(from: style).write(to: recipeURL)
            } catch {
                Log.write("recipe not saved: \(error.localizedDescription)")   // non-fatal
            }
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

    /// DemoTape is free and MIT-licensed; a GitHub star is the only thing we ask in return.
    @objc private func starRepo() {
        if let url = URL(string: "https://github.com/gabosarmiento/demotape") {
            NSWorkspace.shared.open(url)
        }
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
        let captionsReady = Settings.captionsEnabled
            && (Keychain.exists(account: Keychain.sttAPIKeyAccount) || Settings.sttKeyOptional)
        captionsMenuItem?.isEnabled = captionsReady
        captionsMenuItem?.toolTip = captionsReady ? nil
            : "Turn on Captions and add an API key in AI Settings…"

        // ElevenLabs requires its key; local/custom TTS providers can run keyless.
        let ttsIsEleven = (Voiceover.TTSProvider(name: Settings.ttsProvider) == .elevenLabs)
        let voiceoverReady = Settings.voiceoverEnabled
            && (!ttsIsEleven || Keychain.exists(account: Keychain.elevenAPIKeyAccount))
        voiceoverMenuItem?.isEnabled = voiceoverReady
        voiceoverMenuItem?.toolTip = voiceoverReady ? nil
            : "Turn on Voiceover and add an API key in AI Settings…"

        // Avatar needs a HeyGen key and a latest voiceover (with its narration sidecar).
        let hasHeygenKey = Keychain.exists(account: Keychain.heygenAPIKeyAccount)
        let hasVoiceoverTrack = latestVoiceover() != nil
        avatarMenuItem?.isEnabled = hasHeygenKey && hasVoiceoverTrack
        avatarMenuItem?.toolTip = !hasHeygenKey
            ? "Add a HeyGen API key in AI Settings…"
            : (hasVoiceoverTrack ? nil : "Add Voiceover to this recording first")

        // The AI brief uses the OpenAI-compatible key (same one captions use) for both the
        // transcription and the chat model.
        let briefReady = Keychain.exists(account: Keychain.sttAPIKeyAccount)
        briefMenuItem?.isEnabled = briefReady
        briefMenuItem?.toolTip = briefReady ? nil
            : "Add an API key in AI Settings…"
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
        // Turning the mic ON is only honest if macOS grants microphone access. Request it on the
        // spot; if it's denied, keep the mic OFF and point the user to Settings — don't show an
        // "on" mic that can't actually record.
        if Settings.captureMicrophone {
            setMic(false)   // turning off never needs permission
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            setMic(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.setMic(true) } else { self?.micPermissionNeeded() }
                }
            }
        default:
            micPermissionNeeded()
        }
    }

    /// Applies the mic on/off state to the menu item and recorder bar.
    private func setMic(_ on: Bool) {
        Settings.captureMicrophone = on
        micItem.state = on ? .on : .off
        recorderBar?.updateMic(on)
    }

    /// Mic was requested but macOS hasn't granted it — keep it off and offer to open Settings.
    private func micPermissionNeeded() {
        setMic(false)
        let alert = NSAlert()
        alert.messageText = "Microphone access needed"
        alert.informativeText = "To record narration, allow DemoTape to use the microphone in "
            + "System Settings → Privacy & Security → Microphone, then turn the mic on again."
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Not now")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleWebcam() {
        // Same honesty rule as the mic: only show the webcam "on" if macOS grants camera access.
        // Request it on the spot; if denied, keep it OFF and point the user to Settings rather
        // than pretending a camera bubble will appear.
        if Settings.captureWebcam {
            setWebcam(false)   // turning off never needs permission
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setWebcam(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.setWebcam(true) } else { self?.cameraPermissionNeeded() }
                }
            }
        default:
            cameraPermissionNeeded()
        }
    }

    /// Applies the webcam on/off state to the menu item, recorder bar, and preview.
    private func setWebcam(_ on: Bool) {
        Settings.captureWebcam = on
        webcamItem.state = on ? .on : .off
        recorderBar?.updateWebcam(on)
        refreshWebcamPreview()
    }

    /// Camera was requested but macOS hasn't granted it — keep it off and offer to open Settings.
    private func cameraPermissionNeeded() {
        setWebcam(false)
        let alert = NSAlert()
        alert.messageText = "Camera access needed"
        alert.informativeText = "To add a webcam bubble, allow DemoTape to use the camera in "
            + "System Settings → Privacy & Security → Camera, then turn the webcam on again."
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Not now")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
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

    private var recorderSetupPopover: RecorderSetupPopover?
    /// The menu's Input submenu, reused by the recorder bar's setup popover.
    private weak var inputSubmenu: NSMenu?

    private func popUpInputMenu(from anchor: NSView) {
        guard let menu = inputSubmenu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 6), in: anchor)
    }

    /// The bar's ••• popover. Every action routes to the SAME method the menu uses, so the two never
    /// drift apart — the popover is a second door onto the same room, not a second implementation.
    private func showRecorderSetup(from anchor: NSView) {
        if recorderSetupPopover == nil {
            recorderSetupPopover = RecorderSetupPopover(actions: .init(
                setFullScreen: { [weak self] full in
                    guard let self = self else { return }
                    if full { self.selectFullScreen() } else { self.selectArea() }
                },
                openComposer: { [weak self] in self?.openDemoComposer() },
                openBackground: { [weak self] in self?.openBackgroundPicker() },
                toggleBranding: { [weak self] in self?.toggleBranding() },
                toggleTeleprompter: { [weak self] in self?.toggleTeleprompter() },
                toggleAutoZoom: { Settings.autoZoomEnabled = !Settings.autoZoomEnabled },
                // Audio lives in the menu's Input submenu, so the row drops that same submenu here
                // rather than a second copy of it that could drift.
                openAudio: { [weak self] in self?.popUpInputMenu(from: anchor) },
                openWebcam: { [weak self] in self?.openWebcamSettings() },
                openAISettings: { [weak self] in self?.openAISettings() }))
        }
        if recorderSetupPopover?.isShown == true {
            recorderSetupPopover?.close()
        } else {
            recorderSetupPopover?.show(relativeTo: anchor)
        }
    }

    private func presentRecorderBar() {
        if recorderBar == nil {
            let bar = RecorderBarController()
            bar.onStart = { [weak self] in self?.startRecording() }
            bar.onStop = { [weak self] in self?.stopRecording() }
            bar.onCancel = { [weak self] in self?.cancelRecorderBar() }
            bar.onToggleMic = { [weak self] in self?.toggleMic() }
            bar.onToggleWebcam = { [weak self] in self?.toggleWebcam() }
            bar.onOpenSetup = { [weak self] anchor in self?.showRecorderSetup(from: anchor) }
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
        if menu === statusItem.menu {
            // Lets a scripted self-demo confirm its click actually opened the menu.
            Log.write("menu: opened")
        }
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
