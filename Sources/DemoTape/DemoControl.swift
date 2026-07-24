import Foundation
import CoreGraphics

/// External control surface for DemoTape, so an orchestrator (e.g. Kiro driving a browser with
/// Playwright, or a computer-use agent) can run a demo hands-off: **start recording → drive the
/// app → stop → collect the finished video** — without embedding any of that logic (or any
/// third-party dependency) inside DemoTape itself.
///
/// Control comes in over a `demotape://` URL (handled in `AppDelegate`); progress goes back out
/// via a small pollable `control.json` status file. This file holds the **pure, testable** URL
/// parsing; the side effects (starting capture, writing status) live in `AppDelegate`.
///
/// URL grammar:
///   demotape://record/start                         full screen, 3-2-1 countdown
///   demotape://record/start?countdown=0             start immediately (best for automation)
///   demotape://record/start?mode=area&x=&y=&w=&h=   crop to a pixel rect on the main display
///   demotape://record/start?nx=&ny=&nw=&nh=         crop to a normalized rect (0…1, top-left)
///   demotape://record/start?mic=1&webcam=0          override input toggles for this take
///   demotape://record/stop                          stop + auto-render
enum DemoControl {

    /// Where to crop the capture.
    enum Region: Equatable {
        case fullScreen
        case normalized(CGRect)   // 0…1, top-left origin
        case pixels(CGRect)       // device points, top-left origin, main display
    }

    struct StartOptions: Equatable {
        var region: Region = .fullScreen
        var countdown: Int = 3    // seconds; 0 = begin immediately
        var microphone: Bool? = nil   // nil = leave the current setting
        var webcam: Bool? = nil
    }

    enum Command: Equatable {
        case start(StartOptions)
        case stop
        /// Move (and optionally click) the cursor from the RUNNING app process, which holds the
        /// Accessibility grant — so synthetic clicks register and trigger auto-zoom. `click` false
        /// = move only.
        case cursor(x: Double, y: Double, click: Bool)
    }

    /// Parses a `demotape://` control URL into a command. Returns nil for anything unrecognized.
    static func parse(_ url: URL) -> Command? {
        guard url.scheme?.lowercased() == "demotape" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // Action can be the host (demotape://stop) or a path segment (demotape://record/stop).
        var tokens: [String] = []
        if let host = comps.host { tokens.append(host.lowercased()) }
        tokens += comps.path.split(separator: "/").map { $0.lowercased() }

        // Query lookup (case-insensitive keys).
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name.lowercased()] = item.value }
        func dbl(_ k: String) -> Double? { q[k].flatMap(Double.init) }

        if tokens.contains("cursor") {
            guard let x = dbl("x"), let y = dbl("y") else { return nil }
            return .cursor(x: x, y: y, click: tokens.contains("click"))
        }
        if tokens.contains("stop") { return .stop }
        guard tokens.contains("start") else { return nil }
        func flag(_ keys: [String]) -> Bool? {
            for k in keys { if let v = q[k]?.lowercased() {
                if ["1", "true", "yes", "on"].contains(v) { return true }
                if ["0", "false", "no", "off"].contains(v) { return false }
            } }
            return nil
        }

        var opts = StartOptions()
        if let nx = dbl("nx"), let ny = dbl("ny"), let nw = dbl("nw"), let nh = dbl("nh") {
            opts.region = .normalized(CGRect(x: nx, y: ny, width: nw, height: nh))
        } else if let x = dbl("x"), let y = dbl("y"), let w = dbl("w"), let h = dbl("h") {
            opts.region = .pixels(CGRect(x: x, y: y, width: w, height: h))
        } else {
            opts.region = .fullScreen   // also the case for mode=fullscreen
        }
        if let c = q["countdown"], let n = Int(c) { opts.countdown = max(0, n) }
        opts.microphone = flag(["mic", "microphone"])
        opts.webcam = flag(["webcam", "cam", "camera"])
        return .start(opts)
    }

    // MARK: - Status file (pollable by the orchestrator)

    /// Path of the status file the orchestrator polls (`DemoTape/.demotape/control.json`).
    static var statusURL: URL { Paths.supportDirectory.appendingPathComponent("control.json") }

    /// Writes the current control state. `state` is one of idle/countdown/recording/rendering;
    /// `lastOutput` (when known) is the absolute path of the most recent finished video.
    static func writeStatus(state: String, lastOutput: String? = nil) {
        var dict: [String: Any] = [
            "state": state,
            "recording": (state == "recording"),
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let lastOutput = lastOutput { dict["lastOutput"] = lastOutput }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else { return }
        try? data.write(to: statusURL, options: .atomic)
    }
}
