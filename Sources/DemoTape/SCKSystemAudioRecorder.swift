import AVFoundation
import ScreenCaptureKit

/// System-audio capture for macOS 13+ using ScreenCaptureKit (audio-only). This is the ONLY file
/// that imports ScreenCaptureKit, and the whole type is `@available(macOS 13, *)`, so nothing here
/// is compiled into a code path that can run on the legacy (Monterey/Intel) build.
///
/// It attaches an audio-only `SCStream` (no screen frames are consumed) and writes the captured
/// PCM to an AAC `.m4a` via `AVAssetWriter`. That sidecar is later mixed into the styled export
/// alongside the mic track. Video is still captured by the app's existing `AVCaptureScreenInput`
/// pipeline — SCK is used here strictly for the audio the OS won't otherwise hand us.
@available(macOS 13.0, *)
final class SCKSystemAudioRecorder: NSObject, SystemAudioRecorder, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var startedSession = false
    private let sampleQueue = DispatchQueue(label: "dev.demotape.sysaudio.samples")

    func start(to url: URL) throws {
        // Resolve a display to anchor the content filter (SCK requires one even for audio-only).
        let content = try Self.currentContent()
        guard let display = content.displays.first else {
            throw NSError(domain: "DemoTape", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for system-audio capture."])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true   // don't record DemoTape's own sounds
        config.width = 2                             // we consume no video; keep it tiny
        config.height = 2

        // Prepare the AAC writer.
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "DemoTape", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add system-audio track."])
        }
        writer.add(input)
        self.writer = writer
        self.audioInput = input

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream

        // startCapture is async; block briefly so a failure surfaces from start(to:).
        let sema = DispatchSemaphore(value: 0)
        var startError: Error?
        stream.startCapture { error in startError = error; sema.signal() }
        _ = sema.wait(timeout: .now() + 5)
        if let startError = startError {
            self.stream = nil
            throw startError
        }
        writer.startWriting()
        Log.write("SCKSystemAudioRecorder: capturing system audio → \(url.lastPathComponent)")
    }

    func stop(completion: @escaping () -> Void) {
        guard let stream = stream else { completion(); return }
        stream.stopCapture { [weak self] _ in
            guard let self = self else { completion(); return }
            self.audioInput?.markAsFinished()
            self.writer?.finishWriting { completion() }
            self.stream = nil
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let writer = writer, let input = audioInput else { return }
        if writer.status == .failed { return }
        if !startedSession {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            startedSession = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    // MARK: - Helpers

    /// Fetches current shareable content synchronously (called off the main thread by the engine).
    private static func currentContent() throws -> SCShareableContent {
        let sema = DispatchSemaphore(value: 0)
        var result: SCShareableContent?
        var failure: Error?
        SCShareableContent.getWithCompletionHandler { content, error in
            result = content; failure = error; sema.signal()
        }
        _ = sema.wait(timeout: .now() + 5)
        if let failure = failure { throw failure }
        guard let result = result else {
            throw NSError(domain: "DemoTape", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't query shareable content."])
        }
        return result
    }
}
