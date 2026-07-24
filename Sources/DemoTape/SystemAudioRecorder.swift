import AVFoundation

/// Capturing system (output) audio during a recording. This is a **capability**: it exists only
/// where the OS can do it natively. On macOS 13+ the SCK-backed implementation is used; on older
/// systems there is no recorder at all (the UI hides the toggle, and users capture system audio
/// via a loopback device chosen in Audio Source — see `AudioDevices`).
///
/// The modern integration is deliberately isolated: `ScreenCaptureKit` is imported in exactly one
/// file (`SCKSystemAudioRecorder`), fully `@available`-guarded, so it can never affect the legacy
/// capture path that runs on Monterey/Intel.
protocol SystemAudioRecorder: AnyObject {
    /// Begin writing captured system audio to `url` (an `.m4a`). Call off the main actor is fine.
    func start(to url: URL) throws
    /// Stop and finalize; `completion` runs once the file is closed and ready to mux.
    func stop(completion: @escaping () -> Void)
}

/// Factory + availability probe for system-audio capture. The rest of the app only talks to this.
enum SystemAudio {

    /// True when the OS can capture system audio natively (macOS 13+). Drives whether the
    /// "Record System Audio" toggle is shown at all.
    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// A recorder for this OS, or nil when unsupported (older macOS → use a loopback device instead).
    static func makeRecorder() -> SystemAudioRecorder? {
        if #available(macOS 13.0, *) { return SCKSystemAudioRecorder() }
        return nil
    }

    /// Sidecar path for the captured system audio, beside the raw recording.
    static func sidecarURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("sysaudio.m4a")
    }
}
