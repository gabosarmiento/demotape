import AppKit
import Carbon.HIToolbox

@available(macOS 12.3, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = RecordingEngine()
    private let countdown = CountdownController()
    private let hotKey = GlobalHotKey()

    private enum State { case idle, countdown, recording, rendering }
    private var state: State = .idle { didSet { refreshUI() } }

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
        title: "Show Webcam", action: #selector(toggleWebcam), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        // Critical: NSMenu auto-enables items by default, which ignores our manual
        // isEnabled flags. Turn it off so Start/Stop reflect the real state.
        menu.autoenablesItems = false

        startItem.target = self
        stopItem.target = self
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())

        fullScreenItem.target = self
        menu.addItem(fullScreenItem)
        selectAreaItem.target = self
        menu.addItem(selectAreaItem)
        menu.addItem(.separator())

        micItem.target = self
        micItem.state = Settings.captureMicrophone ? .on : .off
        menu.addItem(micItem)
        webcamItem.target = self
        webcamItem.state = Settings.captureWebcam ? .on : .off
        menu.addItem(webcamItem)

        let webcamSettings = NSMenuItem(title: "Webcam Settings…",
                                        action: #selector(openWebcamSettings), keyEquivalent: "")
        webcamSettings.target = self
        menu.addItem(webcamSettings)

        let backgroundItem = NSMenuItem(title: "Background…",
                                        action: #selector(openBackgroundPicker), keyEquivalent: "")
        backgroundItem.target = self
        menu.addItem(backgroundItem)
        menu.addItem(.separator())

        let publishItem = NSMenuItem(title: "Web Publish Latest…",
                                     action: #selector(openWebPublish), keyEquivalent: "")
        publishItem.target = self
        menu.addItem(publishItem)

        let openFolder = NSMenuItem(title: "Open Recordings Folder",
                                    action: #selector(openRecordingsFolder), keyEquivalent: "o")
        openFolder.target = self
        menu.addItem(openFolder)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit DemoTape",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateCaptureModeChecks()

        // Global ⇧⌘S toggles recording without touching the menu (so the click isn't
        // captured at the end of the video). Carbon consumes the key system-wide.
        hotKey.onPressed = { [weak self] in self?.toggleRecording() }
        hotKey.register(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))

        refreshUI()
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

        guard let button = statusItem.button else { return }
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

    @objc private func toggleMic() {
        Settings.captureMicrophone.toggle()
        micItem.state = Settings.captureMicrophone ? .on : .off
    }

    @objc private func toggleWebcam() {
        Settings.captureWebcam.toggle()
        webcamItem.state = Settings.captureWebcam ? .on : .off
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
        let picker = BackgroundPickerController()
        backgroundPicker = picker
        picker.show()
    }

    private var regionSelector: RegionSelector?
    private func updateCaptureModeChecks() {
        fullScreenItem.state = Settings.useRegion ? .off : .on
        selectAreaItem.state = Settings.useRegion ? .on : .off
    }

    @objc private func selectFullScreen() {
        Settings.useRegion = false
        updateCaptureModeChecks()
    }

    @objc private func selectArea() {
        let selector = RegionSelector()
        regionSelector = selector
        selector.selectArea { [weak self] _ in
            DispatchQueue.main.async { self?.updateCaptureModeChecks() }
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
        style.useBackground = Settings.useRegion
        if Settings.useRegion {
            style.backgroundImageURL = backgroundURL()
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
