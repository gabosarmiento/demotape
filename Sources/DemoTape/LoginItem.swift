import Foundation
import ServiceManagement
import AppKit

/// Toggles "launch DemoTape at login".
///
/// Uses the modern `SMAppService` on macOS 13+. On macOS 12 (our floor), that API doesn't
/// exist and the old `SMLoginItemSetEnabled` needs a bundled helper, so we fall back to
/// scripting System Events' login-item list (the user is asked to allow automation once).
enum LoginItem {

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return legacyIsEnabled()
    }

    /// Returns true on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                return true
            } catch {
                Log.write("LoginItem: SMAppService failed: \(error.localizedDescription)")
                return false
            }
        }
        return legacySetEnabled(enabled)
    }

    // MARK: - macOS 12 fallback (System Events login items)

    private static var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "DemoTape"
    }
    private static var appPath: String { Bundle.main.bundlePath }

    private static func legacyIsEnabled() -> Bool {
        let script = "tell application \"System Events\" to get the name of every login item"
        guard let output = runAppleScript(script) else { return false }
        return output.contains(appName)
    }

    private static func legacySetEnabled(_ enabled: Bool) -> Bool {
        let script: String
        if enabled {
            script = "tell application \"System Events\" to make login item at end "
                + "with properties {path:\"\(appPath)\", hidden:false, name:\"\(appName)\"}"
        } else {
            script = "tell application \"System Events\" to delete login item \"\(appName)\""
        }
        return runAppleScript(script) != nil
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error = error {
            Log.write("LoginItem: AppleScript error: \(error)")
            return nil
        }
        return result.stringValue ?? ""
    }
}
