import AppKit

/// The five tools in the Project Studio left rail. Each maps to an existing DemoTape engine;
/// selecting one swaps the bottom parameter panel.
enum StudioTool: Int, CaseIterable {
    case edit, caption, audio, avatar, output

    var title: String {
        switch self {
        case .edit:    return "Edit"
        case .caption: return "Caption"
        case .audio:   return "Audio"
        case .avatar:  return "Avatar"
        case .output:  return "Output"
        }
    }

    /// SF Symbol matching the icons discussed (scissors / rectangle / music note / person / player).
    var symbol: String {
        switch self {
        case .edit:    return "scissors"
        case .caption: return "text.below.rectangle"
        case .audio:   return "music.note"
        case .avatar:  return "person.crop.circle"
        case .output:  return "play.rectangle"
        }
    }
}

/// Services the Project Studio exposes to its tool panels. A panel operates on `currentSource`,
/// shows a candidate on the right via `preview`, and — once the user is happy — bakes it into a
/// new source revision via `approve`. `revert` walks the revision stack back.
@available(macOS 12.3, *)
protocol StudioHost: AnyObject {
    var project: Project { get }
    /// The video the active tool should treat as its input (latest approved revision).
    var currentSource: URL { get }
    /// Show a candidate result in the right-hand player without committing it.
    func preview(_ url: URL)
    /// Commit a result: it becomes the new current source (pushed onto the revision stack).
    func approve(_ url: URL)
    /// Update the status line at the bottom of the window.
    func setStatus(_ text: String, isError: Bool)
    /// Re-scan the project from disk (after a tool writes new derivative files).
    func refreshProject()
}

/// A bottom-half parameter panel for one tool. Panels are plain views; the Studio embeds one at
/// a time and calls `activate` whenever the tool is shown or the source changes.
@available(macOS 12.3, *)
protocol StudioToolPanel: NSView {
    /// Called when the panel becomes visible or the current source changes.
    func activate(host: StudioHost)
}
