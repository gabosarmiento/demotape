import Foundation

/// Derives sibling output locations for a working source file, independent of any Project model.
/// This lets the Studio operate on **any** file the user picks (even one outside the DemoTape
/// folder) — outputs are always written next to the source, keyed off a clean base name.
struct SourcePaths {
    let source: URL

    private static let derivativeMarkers = [".styled", ".tight", ".voiceover", ".captioned", ".avatar"]

    var directory: URL { source.deletingLastPathComponent() }

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

    /// An output beside the source, e.g. `output(suffix: "tight")` → `<base>.tight.mp4`.
    func output(suffix: String, ext: String = "mp4") -> URL {
        directory.appendingPathComponent("\(base).\(suffix).\(ext)")
    }

    /// The Transitions/template output: `<base>-<id>.mp4`.
    func templateOutput(id: String) -> URL {
        directory.appendingPathComponent("\(base)-\(id).mp4")
    }

    /// The recording's webcam sidecar (`<base>.cam.mov`) if it exists.
    var camera: URL? {
        let c = directory.appendingPathComponent("\(base).cam.mov")
        return FileManager.default.fileExists(atPath: c.path) ? c : nil
    }

    /// The recording's event-timeline sidecar (`<base>.events.json`) if it exists.
    var events: URL? {
        let e = directory.appendingPathComponent("\(base).events.json")
        return FileManager.default.fileExists(atPath: e.path) ? e : nil
    }

    /// The original raw screen recording (`<base>.mov`) if it exists — the director composes
    /// from this (a clean screen with no baked-in webcam) rather than the styled master.
    var rawRecording: URL? {
        let r = directory.appendingPathComponent("\(base).mov")
        return FileManager.default.fileExists(atPath: r.path) ? r : nil
    }
}
