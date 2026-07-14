import Foundation

/// Derives the output locations for a working source file. This is the single authority for the
/// per-recording folder layout: **finished** outputs (styled/captioned/voiceover/avatar/template
/// and the `-web` bundle) go at the recording-folder root; the **raw capture + support sidecars**
/// (mov, cam.mov, events/transcript/srt/vtt) live in a hidden `.source/` subfolder.
///
/// It works whether the passed `source` is a final at the root or the raw file inside `.source/`
/// (both resolve to the same recording root), and it degrades gracefully for arbitrary files the
/// user picks from outside the DemoTape folder.
struct SourcePaths {
    let source: URL

    private static let derivativeMarkers = [".styled", ".tight", ".voiceover", ".captioned", ".avatar"]

    /// The recording folder (finals live here). If `source` sits inside a `.source/` subfolder,
    /// the root is that subfolder's parent; otherwise it's the source's own directory.
    var recordingRoot: URL {
        let dir = source.deletingLastPathComponent()
        return dir.lastPathComponent == ".source" ? dir.deletingLastPathComponent() : dir
    }

    /// Hidden subfolder holding the raw capture and support sidecars.
    var sourceDir: URL { recordingRoot.appendingPathComponent(".source", isDirectory: true) }

    /// Directory where finished outputs are written (the recording root).
    var directory: URL { recordingRoot }

    /// The source file name without its extension or any known derivative marker, e.g.
    /// `DemoTape … 01.57.51` from `DemoTape … 01.57.51.styled.tight.mp4`.
    var base: String {
        var b = source.deletingPathExtension().lastPathComponent
        for marker in Self.derivativeMarkers {
            b = b.replacingOccurrences(of: marker, with: "")
        }
        // Strip a trailing "-<templateID>" produced by the Transitions step.
        if let dash = b.lastIndex(of: "-") {
            let tail = b[b.index(after: dash)...]
            if VideoTemplate.byID(String(tail)) != nil { b = String(b[..<dash]) }
        }
        return b
    }

    /// Ensures the hidden `.source/` subfolder exists (call before writing support files).
    @discardableResult
    func ensureSourceDir() -> URL {
        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        return sourceDir
    }

    // MARK: - Finished outputs (recording root)

    /// An output at the recording root, e.g. `output(suffix: "tight")` → `<base>.tight.mp4`.
    func output(suffix: String, ext: String = "mp4") -> URL {
        directory.appendingPathComponent("\(base).\(suffix).\(ext)")
    }

    /// The Transitions/template output: `<base>-<id>.mp4`.
    func templateOutput(id: String) -> URL {
        directory.appendingPathComponent("\(base)-\(id).mp4")
    }

    // MARK: - Support sidecars (.source/)

    /// Location (may not exist yet) of a support sidecar in `.source/`.
    func supportURL(_ suffix: String) -> URL { sourceDir.appendingPathComponent("\(base).\(suffix)") }

    var rawURL: URL { supportURL("mov") }
    var cameraURL: URL { supportURL("cam.mov") }
    var eventsURL: URL { supportURL("events.json") }
    var transcriptURL: URL { supportURL("transcript.json") }
    var srtURL: URL { supportURL("srt") }
    var vttURL: URL { supportURL("vtt") }

    private func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The recording's webcam sidecar (`.source/<base>.cam.mov`) if it exists.
    var camera: URL? { existing(cameraURL) }

    /// The recording's event-timeline sidecar (`.source/<base>.events.json`) if it exists.
    var events: URL? { existing(eventsURL) }

    /// The original raw screen recording (`.source/<base>.mov`) if it exists — the director
    /// composes from this (a clean screen with no baked-in webcam) rather than the styled master.
    var rawRecording: URL? { existing(rawURL) }
}
