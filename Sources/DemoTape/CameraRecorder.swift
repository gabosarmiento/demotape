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

    /// Builds and starts the camera session (warm-up) without writing yet.
    /// If `withMicrophone` is true, the mic is added here so audio + webcam share one
    /// clock (perfect lip-sync, no drift). Returns false if no camera / permission denied.
    func prepare(withMicrophone: Bool = false) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video) else {
            Log.write("CameraRecorder: no camera device")
            return false
        }
        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInput(input)

            // Force ~30fps at a modest resolution. Built-in cameras otherwise drop to
            // ~12fps in low light, which makes the overlay look laggy/choppy.
            configureFor30fps(device)

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
        output.startRecording(to: url, recordingDelegate: delegate)
        outputURL = url
        Log.write("CameraRecorder: recording -> \(url.lastPathComponent)")
        return true
    }

    /// Picks a small format that supports 30fps and locks the frame rate to 30,
    /// preventing the low-light frame-rate drop that makes the overlay choppy.
    private func configureFor30fps(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let candidates = device.formats.filter { fmt in
                let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                let supports30 = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
                return supports30 && d.width <= 1280 && d.height <= 720
            }
            // Smallest area among 30fps-capable formats keeps it light but sharp.
            if let best = candidates.min(by: { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }) {
                device.activeFormat = best
            }
            let fps = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = fps
            device.activeVideoMaxFrameDuration = fps
        } catch {
            Log.write("CameraRecorder: could not lock 30fps: \(error.localizedDescription)")
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
