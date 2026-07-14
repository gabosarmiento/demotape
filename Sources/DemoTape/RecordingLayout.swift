import Foundation

/// Discovers recordings in the per-recording-folder layout and migrates older flat recordings
/// into it. A recording folder sits under `Paths.outputDirectory`; finished outputs live at its
/// root, raw capture + support sidecars in a hidden `.source/` subfolder.
enum RecordingLayout {

    /// Filename remainders (after the recording base) that are *support* files → `.source/`.
    /// Everything else after the base is a finished output → recording root.
    static let supportSuffixes = [".mov", ".cam.mov", ".events.json", ".transcript.json", ".srt", ".vtt"]

    /// The recording base ("DemoTape 2026-07-14 at 21.52.46") at the start of `name`, or nil.
    /// Matches the recorder's `DemoTape yyyy-MM-dd 'at' HH.mm.ss` naming (note the dotted time).
    static func recordingBase(of name: String) -> String? {
        let pattern = "^DemoTape \\d{4}-\\d{2}-\\d{2} at \\d{2}\\.\\d{2}\\.\\d{2}"
        guard let r = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[r])
    }

    static func isSupport(remainder: String) -> Bool { supportSuffixes.contains(remainder) }

    // MARK: - Migration (pure plan + apply)

    /// Given the top-level entry names in the recordings folder, returns the moves needed to group
    /// them into per-recording folders. Paths are relative to `Paths.outputDirectory`. Pure &
    /// testable. `directoryNames` marks which entries are directories (already-migrated folders
    /// are skipped; `-web` bundles are moved as finished outputs).
    static func migrationPlan(names: [String], directoryNames: Set<String> = []) -> [(from: String, to: String)] {
        var moves: [(String, String)] = []
        for name in names {
            if name == "demotape.log" {
                moves.append((name, ".demotape/demotape.log"))
                continue
            }
            guard let base = recordingBase(of: name) else { continue }   // skip unknown files
            let remainder = String(name.dropFirst(base.count))
            // A bare directory named exactly the base is an already-migrated recording folder.
            if remainder.isEmpty && directoryNames.contains(name) { continue }
            if remainder.isEmpty { continue }
            let dest = isSupport(remainder: remainder) ? "\(base)/.source/\(name)" : "\(base)/\(name)"
            if dest != name { moves.append((name, dest)) }
        }
        return moves
    }

    /// Applies the migration in `Paths.outputDirectory`. Non-destructive: creates folders, moves
    /// files, and skips any move whose destination already exists. Best-effort.
    static func migrateFlatRecordings() {
        let fm = FileManager.default
        let root = Paths.outputDirectory
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: []) else { return }
        var names: [String] = []
        var dirs: Set<String> = []
        for e in entries {
            let name = e.lastPathComponent
            names.append(name)
            if (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { dirs.insert(name) }
        }
        let plan = migrationPlan(names: names, directoryNames: dirs)
        guard !plan.isEmpty else { return }
        for (from, to) in plan {
            let src = root.appendingPathComponent(from)
            let dst = root.appendingPathComponent(to)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: src, to: dst)
        }
        Log.write("RecordingLayout: migrated \(plan.count) item(s) into per-recording folders")
    }

    // MARK: - Discovery

    /// Recording folders under the output directory (excludes `.demotape` and hidden entries).
    static func recordingFolders() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: Paths.outputDirectory,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
                && $0.lastPathComponent != ".demotape"
        }
    }

    private static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Newest finished output across all recording folders whose filename ends with `suffix`
    /// (e.g. `.styled.mp4`, `.voiceover.mp4`), optionally filtered by `where`.
    static func latestFinal(suffix: String, where predicate: (URL) -> Bool = { _ in true }) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        for folder in recordingFolders() {
            guard let files = try? fm.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            candidates.append(contentsOf: files.filter { $0.lastPathComponent.hasSuffix(suffix) && predicate($0) })
        }
        return candidates.max { modified($0) < modified($1) }
    }

    /// Newest raw screen recording (`.source/*.mov`, excluding `.cam.mov`) across all folders.
    static func latestRaw() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        for folder in recordingFolders() {
            let src = folder.appendingPathComponent(".source", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: src,
                                                          includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: []) else { continue }
            candidates.append(contentsOf: files.filter {
                $0.pathExtension == "mov" && !$0.lastPathComponent.hasSuffix(".cam.mov")
            })
        }
        return candidates.max { modified($0) < modified($1) }
    }

    /// Newest playable recording (prefers a styled export, else the raw screen capture).
    static func latestRecording() -> URL? { latestFinal(suffix: ".styled.mp4") ?? latestRaw() }
}
