import Foundation

/// A **Project** groups a single screen recording with every file derived from it —
/// the styled export, captions, transcript, voiceover, narration, avatar, tightened cut,
/// and the web-publish folder.
///
/// Grouping is **virtual** (option A): nothing is moved on disk. A project's identity is the
/// raw recording's file stem (e.g. `DemoTape 2026-07-12 at 01.57.51`), and its members are all
/// entries in the output folder whose name begins with that stem. This is backward compatible —
/// every existing recording and derivative already shares that prefix, because derivatives are
/// produced by appending suffixes to the recording's base name.
struct Project: Equatable {

    /// The raw screen recording (`…​.mov`, never the `.cam.mov` webcam track). Source of identity.
    let recording: URL

    /// Recording file name without extension, e.g. `DemoTape 2026-07-12 at 01.57.51`.
    /// Every derivative in this project begins with this string.
    var stem: String { recording.deletingPathExtension().lastPathComponent }

    /// Output directory the project lives in.
    var directory: URL { recording.deletingLastPathComponent() }

    /// A friendly title for the UI (drops the leading "DemoTape " when present).
    var displayName: String {
        let s = stem
        return s.hasPrefix("DemoTape ") ? String(s.dropFirst("DemoTape ".count)) : s
    }

    /// When the recording was made (file creation date, falling back to modification date).
    var createdAt: Date {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let v = try? recording.resourceValues(forKeys: Set(keys))
        return v?.creationDate ?? v?.contentModificationDate ?? .distantPast
    }

    // MARK: - Known derivative locations (may or may not exist on disk)

    /// The "clean" base used by the pipeline: the recording stem with any `.styled` marker
    /// removed, matching the convention in `Voiceover.outputURL` / `narrationURL`.
    private var base: String { stem.replacingOccurrences(of: ".styled", with: "") }

    private func file(_ suffixWithExt: String) -> URL {
        directory.appendingPathComponent("\(base).\(suffixWithExt)")
    }

    var camera: URL     { directory.appendingPathComponent("\(stem).cam.mov") }
    var events: URL     { directory.appendingPathComponent("\(stem).events.json") }
    var styled: URL     { file("styled.mp4") }
    var transcript: URL { file("transcript.json") }
    var srt: URL        { file("styled.srt") }
    var vtt: URL        { file("styled.vtt") }
    var captioned: URL  { file("captioned.mp4") }
    var voiceover: URL  { file("voiceover.mp4") }
    var narration: URL  { file("voiceover.narration.m4a") }
    var tight: URL      { file("tight.mp4") }
    var avatar: URL     { file("avatar.mp4") }

    // MARK: - Membership & state

    /// Whether a path exists on disk.
    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// All files/folders in the output directory that belong to this project (share the stem).
    func members() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { $0.lastPathComponent.hasPrefix(stem) }
                      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Playable video derivatives that currently exist, newest last is not implied — this is by
    /// pipeline order (rawest → most processed) so callers can pick a sensible default source.
    func existingVideos() -> [URL] {
        [recording, styled, tight, captioned, voiceover, avatar].filter(Self.exists)
    }

    /// The most sensible video to show as the initial **source**: the most recently modified
    /// existing derivative, falling back to the styled export, then the raw recording.
    var bestSource: URL {
        let videos = existingVideos()
        if let newest = videos.max(by: { Self.modDate($0) < Self.modDate($1) }) { return newest }
        return Self.exists(styled) ? styled : recording
    }

    var hasStyled: Bool     { Self.exists(styled) }
    var hasCaptions: Bool   { Self.exists(srt) || Self.exists(transcript) }
    var hasVoiceover: Bool  { Self.exists(voiceover) }
    var hasNarration: Bool  { Self.exists(narration) }
    var hasAvatar: Bool     { Self.exists(avatar) }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    static func == (lhs: Project, rhs: Project) -> Bool { lhs.recording == rhs.recording }
}
