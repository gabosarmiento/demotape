import AppKit
import CoreGraphics
import ApplicationServices

/// Single gatekeeper for the two permissions macOS will NOT grant inline — Screen Recording and
/// Accessibility. Both are granted only by ticking a box in System Settings.
///
/// Why this type exists: `CGRequestScreenCaptureAccess()` and
/// `AXIsProcessTrustedWithOptions(prompt:)` are **non-blocking**. They return immediately and ask
/// the WindowServer to display the system lock alert out-of-process. That has two consequences we
/// kept getting wrong:
///
/// 1. **Never open System Settings ourselves alongside the request.** Our `NSWorkspace.open` would
///    win the race and land on an *empty* pane before the app was registered. The lock alert's own
///    "Open System Settings" button is the one that opens the pane with DemoTape already listed
///    (icon and all), because by then the WindowServer has registered the app.
/// 2. **Ask at most once per launch.** Because the call returns instantly, any second call — from
///    another window, a status-refresh timer, a double-click, or the record path — queues a
///    *second* identical lock alert, which is what produced the duplicate prompt. Routing every
///    prompt through here with a once-per-launch latch makes that impossible by construction.
///
/// Requesting also has a useful side effect: it registers the app in the relevant System Settings
/// list, so the user never has to hunt for the bundle with the "+" button.
enum SystemPermissions {

    // MARK: - Screen Recording

    /// Latches once we've seen access granted. A grant can't be revoked while we run (revoking it
    /// kills the capture), so there's no reason to keep asking the system.
    private static var screenRecordingGranted = false

    /// True when macOS currently allows us to capture the screen.
    ///
    /// IMPORTANT: while the status is still undecided, every capture-access check counts as an
    /// *attempt* as far as the WindowServer is concerned, and each attempt can queue another lock
    /// alert (they then surface one after another as the user clicks/activates the app). So this
    /// must never be polled on a timer — call it on discrete events only (window activation, a
    /// button press), which is what the UI now does.
    static var hasScreenRecording: Bool {
        if screenRecordingGranted { return true }
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        return screenRecordingGranted
    }

    /// Whether we've already asked the system this launch (so the UI can show the right affordance).
    private(set) static var didRequestScreenRecording = false

    /// Fires the system's Screen Recording lock alert — at most once per launch.
    /// - Returns: `true` if the prompt was actually issued, `false` if it was suppressed because
    ///   access is already granted or we already asked this launch (the alert is already up or
    ///   answered, so a second call would only stack a duplicate).
    @discardableResult
    static func requestScreenRecording() -> Bool {
        if hasScreenRecording {
            Log.write("SystemPermissions: screen recording already granted; no prompt")
            return false
        }
        if didRequestScreenRecording {
            Log.write("SystemPermissions: screen recording already requested this launch; suppressing duplicate prompt")
            return false
        }
        didRequestScreenRecording = true
        Log.write("SystemPermissions: requesting screen recording (system lock alert)")
        // Do NOT also open System Settings here — see the note above.
        _ = CGRequestScreenCaptureAccess()
        return true
    }

    // MARK: - Accessibility

    /// True when macOS currently trusts us for Accessibility (needed for key badges).
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    private(set) static var didRequestAccessibility = false

    /// Fires the system's Accessibility lock alert — at most once per launch.
    /// - Returns: `true` if the prompt was actually issued.
    @discardableResult
    static func requestAccessibility() -> Bool {
        if hasAccessibility {
            Log.write("SystemPermissions: accessibility already granted; no prompt")
            return false
        }
        if didRequestAccessibility {
            Log.write("SystemPermissions: accessibility already requested this launch; suppressing duplicate prompt")
            return false
        }
        didRequestAccessibility = true
        Log.write("SystemPermissions: requesting accessibility (system lock alert)")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        return true
    }

    // MARK: - Settings panes

    /// Opens a Privacy pane directly. Only use this when we are NOT also issuing a request (e.g.
    /// the user already answered the prompt and now needs to flip the box by hand).
    static func openSettings(_ pane: Pane) {
        Log.write("SystemPermissions: opening settings pane \(pane)")
        if let url = URL(string: pane.urlString) { NSWorkspace.shared.open(url) }
    }

    enum Pane: String {
        case screenRecording, accessibility, microphone, camera, notifications

        var urlString: String {
            let prefix = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
            switch self {
            case .screenRecording: return prefix + "ScreenCapture"
            case .accessibility: return prefix + "Accessibility"
            case .microphone: return prefix + "Microphone"
            case .camera: return prefix + "Camera"
            case .notifications: return "x-apple.systempreferences:com.apple.preference.notifications"
            }
        }
    }
}
