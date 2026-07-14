import Foundation

/// Filesystem locations for DemoTape. Kept free of availability gates so the
/// menu and folder actions work regardless of macOS version.
///
/// Layout (v5.7+): each recording lives in its own folder under `outputDirectory`, with the
/// shareable outputs at the folder root and the raw capture + support sidecars tucked into a
/// hidden `.source/` subfolder:
///
///   DemoTape/
///     DemoTape 2026-07-14 at 21.52.46/
///       …styled.mp4                 (rendered video)
///       …-web/                       (Web Publish bundle — what you share)
///       .source/
///         …mov  …cam.mov  …events.json  …transcript.json  …srt  …vtt
///     .demotape/                      (logs + app support; hidden)
enum Paths {
    static var outputDirectory: URL {
        // User-selected custom directory, if set and creatable.
        let custom = Settings.outputDirectoryPath
        if !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
                || FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("DemoTape", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Hidden support directory for logs and app files (`DemoTape/.demotape/`).
    static var supportDirectory: URL {
        let dir = outputDirectory.appendingPathComponent(".demotape", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
