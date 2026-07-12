import AppKit

/// Guards against the most common cause of DemoTape's Screen Recording permission
/// silently breaking: the app running from somewhere other than `/Applications`.
///
/// macOS ties TCC permissions (Screen Recording, Microphone, Camera) to a bundle's
/// identity *and* its on-disk location. Two situations quietly invalidate a granted
/// permission and force the user to remove/re-add the app in System Settings:
///
///  1. **App Translocation** — when a quarantined app is launched from `~/Downloads`
///     (or any non-standard spot), Gatekeeper runs it from a randomized read-only
///     path. Permissions granted to that ephemeral path never stick.
///  2. **Duplicate bundles** — a copy left in `~/Downloads`, the DMG, or a build
///     folder can grab the permission slot instead of the `/Applications` copy.
///
/// This runs once at launch, does nothing when everything looks right, and otherwise
/// shows a single, actionable alert instead of leaving the user to discover a broken
/// recorder mid-demo.
@available(macOS 12.3, *)
enum LaunchLocationGuard {

    static func check() {
        let path = Bundle.main.bundlePath

        // 1) App Translocation: the bundle lives under a randomized, read-only mount.
        if isTranslocated(path) {
            warn(title: "Move DemoTape to Applications",
                 body: "DemoTape is running from a temporary, read-only location, so macOS "
                     + "won't remember its Screen Recording permission.\n\n"
                     + "Quit DemoTape, drag it into your Applications folder, then launch it "
                     + "from there.")
            return
        }

        // 2) Not installed in /Applications (or ~/Applications). Recording may still work,
        // but permissions are far more likely to reset on the next rebuild/update.
        if !isInApplications(path) {
            warn(title: "Run DemoTape from Applications",
                 body: "DemoTape isn't in your Applications folder (it's at:\n\(path)).\n\n"
                     + "macOS can drop its Screen Recording permission when the app runs from "
                     + "another location or a second copy exists. Move it into Applications and "
                     + "launch it from there to keep permissions stable.")
        }
    }

    /// A translocated app path looks like `/private/var/folders/…/AppTranslocation/…`.
    private static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    private static func isInApplications(_ path: String) -> Bool {
        if path.hasPrefix("/Applications/") { return true }
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        return path.hasPrefix(userApps + "/")
    }

    private static func warn(title: String, body: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "Open Applications Folder")
        alert.addButton(withTitle: "Continue Anyway")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
    }
}
