import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia

/// Recording engine based on the classic AVCaptureScreenInput + AVCaptureMovieFileOutput
/// pipeline. ScreenCaptureKit delivers zero frames on this Monterey machine, so we use
/// the older AVFoundation screen-capture path (works macOS 10.15+), which records
/// directly to an H.264 .mov file. Pattern from nonstrict.eu (Screen Studio's backend team).
final class RecordingEngine {

    var onStateChange: ((Bool) -> Void)?

    private var session: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?
    private let recordingDelegate = RecordingDelegate()
    private let eventRecorder = EventRecorder()
    private let cameraRecorder = CameraRecorder()
    private var outputURL: URL?
    private var isRecording = false
    private var isPrepared = false
    private var webcamPrepared = false
    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var eventStartDate: Date?
    private var regionRect: CGRect?   // top-left global, for event normalization

    /// Populated after stop() if a webcam was recorded.
    private(set) var lastCameraURL: URL?

    /// System-audio capture (macOS 13+). Populated after stop() when a sidecar was written.
    private(set) var lastSystemAudioURL: URL?
    private var systemAudioRecorder: SystemAudioRecorder?
    private var pendingSystemAudioURL: URL?

    private func requestPermission(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    // MARK: - Control

    /// Phase 1: build and start the capture sessions so the camera/screen warm up.
    /// Called during the countdown so recording can begin instantly at zero.
    func prepare() async throws {
        guard !isRecording, !isPrepared else { return }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw NSError(domain: "DemoTape", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Screen Recording permission is required.\n\nOpen System Preferences > Security & Privacy > Privacy > Screen Recording, enable DemoTape, then quit and reopen the app."])
        }

        displayID = CGMainDisplayID()
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let input = AVCaptureScreenInput(displayID: displayID) else {
            throw NSError(domain: "DemoTape", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create screen input for the main display."])
        }
        input.capturesCursor = false
        input.capturesMouseClicks = false
        input.minFrameDuration = CMTime(value: 1, timescale: 30)

        // Region capture: crop to the selected area (AVCaptureScreenInput.cropRect is
        // in display points with a bottom-left origin).
        regionRect = nil
        let bounds = CGDisplayBounds(displayID)
        if Settings.useRegion {
            let rx = CGFloat(Settings.regionX) * bounds.width
            let ryTop = CGFloat(Settings.regionY) * bounds.height
            let rw = CGFloat(Settings.regionW) * bounds.width
            let rh = CGFloat(Settings.regionH) * bounds.height
            input.cropRect = CGRect(x: rx, y: bounds.height - ryTop - rh, width: rw, height: rh)
            regionRect = CGRect(x: rx, y: ryTop, width: rw, height: rh) // top-left for events
            Log.write("prepare(): region crop \(Int(rw))x\(Int(rh))")
        } else if Settings.teleprompterActive {
            // Full screen minus a thin strip (on the chosen edge), so the teleprompter that
            // scrolls in that strip is not part of the recording.
            let (crop, region) = TeleprompterStrip.crop(
                width: bounds.width, height: bounds.height,
                edge: Settings.teleprompterStripEdge,
                fraction: CGFloat(Settings.teleprompterTopStripFraction))
            input.cropRect = crop
            regionRect = region
            Log.write("prepare(): full screen minus teleprompter \(Settings.teleprompterStripEdge) strip")
        }

        guard session.canAddInput(input) else {
            throw NSError(domain: "DemoTape", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add screen input to the capture session."])
        }
        session.addInput(input)

        // Microphone routing: when the webcam is on, the mic goes into the CAMERA
        // session (audio + webcam share one clock → no lip-sync drift). Otherwise it
        // goes into the screen session (audio + screen share one clock).
        var wantMic = false
        if Settings.captureMicrophone { wantMic = await requestPermission(.audio) }
        webcamPrepared = false
        var micInCamera = false
        if Settings.captureWebcam, await requestPermission(.video) {
            webcamPrepared = cameraRecorder.prepare(withMicrophone: wantMic)
            micInCamera = webcamPrepared && wantMic
        }
        if wantMic, !micInCamera, let mic = AudioDevices.selected(),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
            Log.write("prepare(): audio input '\(mic.localizedName)' in screen session")
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            throw NSError(domain: "DemoTape", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add movie output to the capture session."])
        }
        session.addOutput(output)
        session.startRunning() // warm up the screen session now

        self.session = session
        self.movieOutput = output
        isPrepared = true
        Log.write("prepare(): sessions warmed up (webcam=\(webcamPrepared))")
    }

    /// Phase 2: begin writing to disk. Fast, because sessions are already running.
    func beginRecording() {
        guard isPrepared, let output = movieOutput else { return }

        let url = Self.makeOutputURL()
        recordingDelegate.startDate = nil
        recordingDelegate.onStart = { Log.write("delegate: didStartRecording") }
        output.startRecording(to: url, recordingDelegate: recordingDelegate)

        lastCameraURL = nil
        if webcamPrepared {
            let camURL = url.deletingPathExtension().appendingPathExtension("cam.mov")
            if cameraRecorder.begin(to: camURL) { lastCameraURL = camURL }
        }

        eventStartDate = Date()
        eventRecorder.start(displayID: displayID, region: regionRect)

        // System audio (macOS 13+ only): capture to a sidecar alongside the recording. Entirely
        // optional and quarantined — any failure here must never break the screen recording.
        lastSystemAudioURL = nil
        if Settings.captureSystemAudio, let recorder = SystemAudio.makeRecorder() {
            let sidecar = SystemAudio.sidecarURL(for: url)
            do {
                try recorder.start(to: sidecar)
                systemAudioRecorder = recorder
                pendingSystemAudioURL = sidecar
            } catch {
                Log.write("beginRecording(): system audio unavailable (\(error.localizedDescription))")
                systemAudioRecorder = nil
            }
        }

        self.outputURL = url
        self.isRecording = true
        isPrepared = false
        onStateChange?(true)
    }

    func stop() async -> URL? {
        guard isRecording, let output = movieOutput, let session = session else {
            Log.write("stop(): not recording")
            return nil
        }
        isRecording = false

        // Wait for the file to be fully finalized via the delegate callback.
        let error: Error? = await withCheckedContinuation { continuation in
            recordingDelegate.onFinish = { err in continuation.resume(returning: err) }
            output.stopRecording()
        }
        recordingDelegate.onFinish = nil
        session.stopRunning()

        // Finalize the system-audio sidecar (if capturing), then expose it for the render mix.
        if let recorder = systemAudioRecorder {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                recorder.stop { continuation.resume() }
            }
            systemAudioRecorder = nil
            if let sidecar = pendingSystemAudioURL,
               FileManager.default.fileExists(atPath: sidecar.path) {
                lastSystemAudioURL = sidecar
                Log.write("stop(): system audio sidecar → \(sidecar.lastPathComponent)")
            }
            pendingSystemAudioURL = nil
        }

        // Stop the webcam recording (if any) and keep its URL for the renderer.
        let camStart = cameraRecorder.startDate
        let camURL = await cameraRecorder.stop()
        lastCameraURL = camURL

        // Offset between screen and webcam start, so the renderer can align the PiP.
        var cameraOffset = 0.0
        if camURL != nil, let screenStart = recordingDelegate.startDate, let camStart = camStart {
            cameraOffset = camStart.timeIntervalSince(screenStart)
            Log.write("stop(): cameraStartOffset=\(cameraOffset)s")
        }

        // How far the video's first frame lagged the event clock (cursor alignment).
        var eventOffset = 0.0
        if let screenStart = recordingDelegate.startDate, let eventStart = eventStartDate {
            eventOffset = screenStart.timeIntervalSince(eventStart)
            Log.write("stop(): eventTimeOffset=\(eventOffset)s")
        }

        // Write the event-timeline sidecar next to the video.
        if let videoURL = outputURL {
            eventRecorder.stop(videoURL: videoURL, cameraOffset: cameraOffset, eventOffset: eventOffset)
        }

        let url = outputURL
        let fileExists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        var size = 0
        if let url = url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? Int {
            size = bytes
        }
        Log.write("stop(): error=\(String(describing: error)) exists=\(fileExists) size=\(size)")

        let succeeded = error == nil && fileExists && size > 0

        self.session = nil
        self.movieOutput = nil
        self.outputURL = nil
        onStateChange?(false)

        if !succeeded, let url = url { try? FileManager.default.removeItem(at: url) }
        return succeeded ? url : nil
    }

    // MARK: - Helpers

    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "DemoTape \(formatter.string(from: Date()))"
        // Raw capture goes in the recording folder's hidden .source/ subfolder; the styled export
        // and web bundle are written at the folder root later. cam.mov + events.json land here too
        // (they derive as siblings of this URL).
        let sourceDir = Paths.outputDirectory
            .appendingPathComponent(base, isDirectory: true)
            .appendingPathComponent(".source", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        return sourceDir.appendingPathComponent("\(base).mov")
    }
}

// MARK: - Recording delegate

private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    var onStart: (() -> Void)?
    var onFinish: ((Error?) -> Void)?
    var startDate: Date?

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        startDate = Date()
        onStart?()
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        onFinish?(error)
    }
}
