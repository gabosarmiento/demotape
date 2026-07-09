import Foundation

/// Filesystem locations for DemoTape. Kept free of availability gates so the
/// menu and folder actions work regardless of macOS version.
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
}
