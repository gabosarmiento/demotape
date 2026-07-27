import Foundation
import AVFoundation

/// Records the webcam to its own file (video only) in parallel with the screen
/// recording. The renderer composites it as a rounded picture-in-picture. Kept
/// separate so screen + mic audio stay perfectly in sync.
final class CameraRecorder {
    private var session: AVCaptureSession?
    private var output: AVCaptureMovieFileOutput?
    private let delegate = CameraDelegate()
    private var outputURL: URL?

    /// Wall-clock time the camera actually began recording (for PiP sync).
    var startDate: Date? { delegate.startDate }

    /// Recording use: a small picture-in-picture bubble, or a full-frame standalone video.
    enum Quality {
        case bubble       // ≤720p, smallest — composited as a rounded PiP over the screen recording
        case standalone   // ~1080p — the camera IS the video (webcam-only mode)
    }

    private var mirrored = false

    /// Builds and starts the camera session (warm-up) without writing yet.
    /// If `withMicrophone` is true, the mic is added here so audio + webcam share one
    /// clock (perfect lip-sync, no drift). `mirrored` flips the recorded frame horizontally (a
    /// talking-head usually wants the mirror image they're used to). Returns false if no camera /
    /// permission denied.
    func prepare(withMicrophone: Bool = false, quality: Quality = .bubble, mirrored: Bool = false) -> Bool {
        self.mirrored = mirrored
        guard let device = AVCaptureDevice.default(for: .video) else {
            Log.write("CameraRecorder: no camera device")
            return false
        }
        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInput(input)

            // Force ~30fps at a resolution suited to the use. Built-in cameras otherwise drop to
            // ~12fps in low light, which looks choppy.
            switch quality {
            case .bubble:     configureFormat(device, maxWidth: 1280, maxHeight: 720, pickLargest: false)
            case .standalone: configureFormat(device, maxWidth: 1920, maxHeight: 1080, pickLargest: true)
            }

            if withMicrophone, let mic = AudioDevices.selected(),
               let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
                session.addInput(micInput)
                Log.write("CameraRecorder: audio input '\(mic.localizedName)' added (shared clock)")
            }

            let output = AVCaptureMovieFileOutput()
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)

            session.startRunning() // warm up the camera now

            self.session = session
            self.output = output
            Log.write("CameraRecorder: prepared (warming up)")
            return true
        } catch {
            Log.write("CameraRecorder: prepare failed \(error.localizedDescription)")
            return false
        }
    }

    /// Begins writing to `url`. Fast — the session is already running.
    @discardableResult
    func begin(to url: URL) -> Bool {
        guard let output = output else { return false }
        // Mirror the recorded frame if asked. Must turn off the automatic adjustment first, or the
        // explicit value is ignored. Front cameras support mirroring; if not, we just record straight.
        if let conn = output.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = mirrored
        }
        output.startRecording(to: url, recordingDelegate: delegate)
        outputURL = url
        Log.write("CameraRecorder: recording -> \(url.lastPathComponent) (mirrored: \(mirrored))")
        return true
    }

    /// Chooses which capture format sizes are acceptable for a target box. Pure, so the size policy
    /// is unit-tested: standalone wants the LARGEST format that still fits 1080p (crisp, but never
    /// 4K); the bubble wants the smallest (light). Returns the indices of acceptable `sizes`.
    static func acceptableFormatSizes(_ sizes: [(w: Int, h: Int, maxFps: Double)],
                                      maxWidth: Int, maxHeight: Int) -> [Int] {
        sizes.enumerated().filter { _, s in
            s.maxFps >= 30 && s.w <= maxWidth && s.h <= maxHeight
        }.map { $0.offset }
    }

    /// Picks a 30fps-capable format within the box (largest for standalone, smallest for the bubble)
    /// and locks the frame rate to 30 to prevent the low-light frame-rate drop.
    private func configureFormat(_ device: AVCaptureDevice, maxWidth: Int, maxHeight: Int, pickLargest: Bool) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let candidates = device.formats.filter { fmt in
                let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                let supports30 = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
                return supports30 && d.width <= maxWidth && d.height <= maxHeight
            }
            func area(_ f: AVCaptureDevice.Format) -> Int {
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return Int(d.width) * Int(d.height)
            }
            let best = pickLargest ? candidates.max { area($0) < area($1) }
                                   : candidates.min { area($0) < area($1) }
            if let best = best { device.activeFormat = best }
            let fps = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = fps
            device.activeVideoMaxFrameDuration = fps
        } catch {
            Log.write("CameraRecorder: could not set format: \(error.localizedDescription)")
        }
    }

    func stop() async -> URL? {
        guard let output = output, let session = session else { return nil }
        _ = await withCheckedContinuation { (c: CheckedContinuation<Error?, Never>) in
            delegate.onFinish = { c.resume(returning: $0) }
            output.stopRecording()
        }
        delegate.onFinish = nil
        session.stopRunning()
        self.session = nil
        self.output = nil
        let url = outputURL
        outputURL = nil
        if let url = url, FileManager.default.fileExists(atPath: url.path) { return url }
        return nil
    }
}

private final class CameraDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    var onFinish: ((Error?) -> Void)?
    var startDate: Date?
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        startDate = Date()
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        onFinish?(error)
    }
}
