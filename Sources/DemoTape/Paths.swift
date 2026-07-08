import Foundation

/// Filesystem locations for DemoTape. Kept free of availability gates so the
/// menu and folder actions work regardless of macOS version.
enum Paths {
    static var outputDirectory: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("DemoTape", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
