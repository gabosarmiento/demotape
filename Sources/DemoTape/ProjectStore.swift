import Foundation

/// Discovers `Project`s in an output directory by finding raw recordings and grouping their
/// derivatives virtually (see `Project`). No files are moved or renamed.
enum ProjectStore {

    /// Lists projects in `directory`, newest first. A project is anchored on each raw screen
    /// recording — a `.mov` that is **not** a `.cam.mov` webcam track.
    static func list(in directory: URL = Paths.outputDirectory) -> [Project] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let recordings = entries.filter { isRawRecording($0) }
        let projects = recordings.map { Project(recording: $0) }
        return projects.sorted { $0.createdAt > $1.createdAt }
    }

    /// The most recent project, if any.
    static func latest(in directory: URL = Paths.outputDirectory) -> Project? {
        list(in: directory).first
    }

    /// The project that a given file belongs to (by stem prefix), if it can be resolved.
    static func project(for file: URL, in directory: URL = Paths.outputDirectory) -> Project? {
        let name = file.deletingPathExtension().lastPathComponent
        // Match the recording whose stem is the longest prefix of this file's name.
        return list(in: directory)
            .filter { name.hasPrefix($0.stem) || file.lastPathComponent.hasPrefix($0.stem) }
            .max { $0.stem.count < $1.stem.count }
    }

    /// A raw recording is a `.mov` that isn't the `.cam.mov` webcam sidecar.
    private static func isRawRecording(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".mov") && !name.hasSuffix(".cam.mov")
    }
}
