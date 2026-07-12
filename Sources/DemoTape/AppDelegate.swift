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
    private let aboutController = AboutController()
    private var welcomeController: WelcomeController?
    private weak var captionsMenuItem: NSMenuItem?
    private weak var voiceoverMenuItem: NSMenuItem?
    private weak var avatarMenuItem: NSMenuItem?
    private var avatarPresenterController: AvatarPresenterController?

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

        let studioItem = NSMenuItem(title: "Open Project Studio…",
                                    action: #selector(openProjectStudio), keyEquivalent: "e")
        studioItem.target = self
        menu.addItem(studioItem)
        menu.addItem(.separator())

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

        let avatarItem = NSMenuItem(title: "Generate Avatar Presenter for Latest…",
                                    action: #selector(generateAvatarPresenter), keyEquivalent: "")
        avatarItem.target = self
        aiMenu.addItem(avatarItem)
        self.avatarMenuItem = avatarItem

        aiItem.submenu = aiMenu
        // Enable each action only when its feature is turned on with a key ready. The delegate
        // refreshes this every time the submenu opens.
        self.captionsMenuItem = captionsItem
        self.voiceoverMenuItem = voiceoverItem
        aiMenu.delegate = self
        menu.addItem(aiItem)

        let templatesItem = NSMenuItem(title: "Apply Template to Latest…",
                                       action: #selector(openTemplateGallery), keyEquivalent: "")
        templatesItem.target = self
        menu.addItem(templatesItem)

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

        // --- System Preferences (submenu of checkable toggles, like Input) ---
        let sysItem = NSMenuItem(title: "System Preferences", action: nil, keyEquivalent: "")
        let sysMenu = NSMenu(); sysMenu.autoenablesItems = false

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
                          teleprompterItem, brandingItem, tightenItem, aiItem, templatesItem,
                          publishItem, changeDir]

        statusItem.menu = menu
        updateCaptureModeChecks()

        // Global ⇧⌘S toggles recording without touching the menu (so the click isn't
        // captured at the end of the video). Carbon consumes the key system-wide.
        hotKey.onPressed = { [weak self] in self?.toggleRecording() }
        hotKey.register(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))

        refreshUI()

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
        Notifier.shared.renderStarted()   // "cooking your DemoTape…"
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
                // Open the Project Studio on the fresh recording so the user lands right in
                // the output control panel once rendering is done.
                self.openStudio(for: ProjectStore.project(for: raw) ?? Project(recording: raw))
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
            alert.informativeText = "macOS may need permission to manage login items. Try again, "
                + "or add DemoTape manually in System Settings → General → Login Items."
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
        captionsMenuItem?.isEnabled = Settings.captionsEnabled
            && Keychain.exists(account: Keychain.sttAPIKeyAccount)
        voiceoverMenuItem?.isEnabled = Settings.voiceoverEnabled
            && Keychain.exists(account: Keychain.elevenAPIKeyAccount)
        // Avatar needs a HeyGen key and a latest voiceover (with its narration sidecar).
        avatarMenuItem?.isEnabled = Keychain.exists(account: Keychain.heygenAPIKeyAccount)
            && latestVoiceover() != nil
    }

    /// Newest `…voiceover.mp4` whose narration sidecar still exists.
    private func latestVoiceover() -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Paths.outputDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        func modified(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        return items
            .filter { $0.lastPathComponent.hasSuffix(".voiceover.mp4") }
            .filter { fm.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("narration.m4a").path) }
            .max { modified($0) < modified($1) }
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
        let controller = AvatarPresenterController(voiceoverVideo: voiceover, narrationAudio: narration,
                                                   apiKey: key, voiceGender: Settings.elevenVoiceGender)
        avatarPresenterController = controller
        controller.show(onClose: { [weak self] in self?.avatarPresenterController = nil })
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
        guard Settings.voiceoverEnabled, !key.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Enable voiceover first"
            alert.informativeText = (Keychain.exists(account: Keychain.elevenAPIKeyAccount))
                ? "Turn on Voiceover in AI Settings to generate narration."
                : "Voiceover uses ElevenLabs text-to-speech. Add and test your ElevenLabs key in "
                    + "AI Settings, enable Voiceover, then try again."
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

    private var templateGalleryController: TemplateGalleryController?
    @objc private func openTemplateGallery() {
        guard let video = latestRecording() else {
            presentPermissionHelp(title: "No recording found",
                                  message: "Record something first — templates re-edit your latest recording.")
            return
        }
        let controller = TemplateGalleryController(master: video)
        templateGalleryController = controller  // retain while open
        controller.show()
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
        // Gate on the captions feature being enabled + a saved key. Otherwise, send to settings.
        let key = Keychain.get(account: Keychain.sttAPIKeyAccount) ?? ""
        guard Settings.captionsEnabled, !key.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Enable captions first"
            alert.informativeText = (Keychain.exists(account: Keychain.sttAPIKeyAccount))
                ? "Turn on Captions in AI Settings to transcribe this recording."
                : "Captions use an OpenAI-compatible speech-to-text API. Add and test your key in "
                    + "AI Settings, enable Captions, then try again."
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

    private var projectStudioController: ProjectStudioController?
    @objc private func openProjectStudio() {
        openStudio(for: ProjectStore.latest())
    }

    /// Opens the Project Studio on a specific project (or the latest). Shows guidance if there's
    /// nothing recorded yet.
    private func openStudio(for project: Project?) {
        guard let project = project else {
            presentPermissionHelp(
                title: "Nothing to open yet",
                message: "Record something first — Project Studio works on a recording and everything you make from it.")
            return
        }
        if let existing = projectStudioController {
            existing.show(onClose: { [weak self] in self?.projectStudioController = nil })
            return
        }
        let controller = ProjectStudioController(project: project)
        projectStudioController = controller
        controller.show(onClose: { [weak self] in self?.projectStudioController = nil })
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
            regionOverlay?.aspect = AreaPreset.named(Settings.regionPreset).aspect
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
        refreshAIMenuItems()
    }
}
