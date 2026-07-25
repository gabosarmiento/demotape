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
        /// `glideMs` > 0 animates the trip instead of teleporting: eased, slightly arced, with a
        /// small overshoot-and-settle at the end. A hard warp reads as a robot on video, and the
        /// travel itself is what carries the viewer's eye between two points, so a demo should
        /// almost always glide. The animation runs inside the app (one URL per move) because
        /// issuing a URL per intermediate point would stutter at ~150ms of shell overhead each.
        case cursor(x: Double, y: Double, click: Bool, glideMs: Int = 0)
        /// Type text as REAL OS keystrokes, from the running app (which holds the Accessibility
        /// grant). This matters for more than fidelity: auto-zoom is driven by clicks *and keys*, so
        /// keystrokes the app can't observe leave the camera wide while the user types. A browser
        /// automation tool's synthetic typing is invisible to our global event monitor, so the text
        /// appeared with no zoom held on the field. Typing through the app records real KeySamples,
        /// which hold the zoom exactly as they do when a human types.
        /// `cps` is characters per second (0 = a sensible human default).
        ///
        /// `expectedApp` is a REQUIRED-in-practice safety catch: synthetic keystrokes go to whichever
        /// window holds system focus, not to any window the caller has a handle on. If focus has
        /// moved, the text lands in the user's editor or terminal — which can be destructive, and is
        /// invisible to the caller because the keys still get recorded. When set, the app refuses to
        /// type unless that application is frontmost.
        case type(text: String, cps: Double, expectedApp: String?)
        /// Record typing activity WITHOUT posting keystrokes, so the auto-zoom holds on the focused
        /// field while some other tool types the visible text.
        ///
        /// This exists because browsers reject synthetic key events that carry no virtual keycode:
        /// posting real keystrokes at a Chromium window types nothing, and if another window is
        /// frontmost it types there instead. So a browser-driven demo must let the automation tool
        /// enter the text — and then nothing tells DemoTape that typing is happening, leaving the
        /// camera to drift off the field mid-sentence. `chars` is how many characters are being
        /// typed and `cps` the rate, which together reproduce the same zoom hold real typing gives.
        case typingActivity(chars: Int, cps: Double)
        /// Open one of DemoTape's own windows. This exists so a walkthrough *of DemoTape itself*
        /// can be scripted: an orchestrator can't reliably click menu rows (their screen rects
        /// aren't discoverable from outside), but it can ask the app to show a window directly.
        /// `holdMs` only applies to `.menu`: an open NSMenu runs a nested tracking loop that stalls
        /// incoming control URLs until it closes, so the app must dismiss its own menu after the
        /// requested time. Without it a scripted walkthrough deadlocks behind its own menu.
        case openUI(Window, holdMs: Int = 0)
        /// Resolve a target from the LIVE UI (by label/role, via AppKit for our own windows or the
        /// Accessibility API for any other app) and act on it. This is the coordinate-free path:
        /// `find` publishes the element's rect, `click` glides to it and clicks it.
        case element(query: UIQuery.Query, click: Bool)
        /// Write the current UI tree to `ui-tree.json` so an agent can read what's on screen.
        case dumpUI(app: String?)
    }

    /// Windows reachable through `demotape://ui/open?window=…`.
    ///
    /// `menu` isn't a window — it drops the menu-bar menu open. Clicking the icon with a synthetic
    /// event doesn't reliably reach a status item, so the app performs the click on itself instead,
    /// which needs no screen coordinates at all.
    enum Window: String, Equatable, CaseIterable {
        case about, publish, composer, settings, welcome, menu
    }

    /// Parses a `demotape://` control URL into a command. Returns nil for anything unrecognized.
    static func parse(_ url: URL) -> Command? {
        guard url.scheme?.lowercased() == "demotape" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // Action can be the host (demotape://stop) or a path segment (demotape://record/stop).
        var tokens: [String] = []
        if let host = comps.host { tokens.append(host.lowercased()) }
        tokens += comps.path.split(separator: "/").map { $0.lowercased() }

        // Query lookup (case-insensitive keys). `+` is decoded as a space: URLComponents leaves it
        // literal, but callers building URLs from shells and scripts routinely use it for spaces,
        // which otherwise silently fails to match a label like "Check for Updates".
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            q[item.name.lowercased()] = item.value?.replacingOccurrences(of: "+", with: " ")
        }
        func dbl(_ k: String) -> Double? { q[k].flatMap(Double.init) }

        if tokens.contains("typing") {
            // demotape://typing?chars=42&cps=14  — activity only, nothing is posted.
            guard let chars = dbl("chars"), chars > 0 else { return nil }
            return .typingActivity(chars: Int(chars), cps: max(0, dbl("cps") ?? 0))
        }
        if tokens.contains("type") {
            // demotape://type?text=hello%20world&cps=14&app=Chromium
            guard let text = q["text"], !text.isEmpty else { return nil }
            return .type(text: text, cps: max(0, dbl("cps") ?? 0), expectedApp: q["app"])
        }
        if tokens.contains("cursor") {
            guard let x = dbl("x"), let y = dbl("y") else { return nil }
            // demotape://cursor/glide?x=&y=&ms=420  (ms also accepted as `glide`)
            var glide = Int(dbl("ms") ?? dbl("glide") ?? 0)
            if tokens.contains("glide"), glide <= 0 { glide = 420 }   // sensible default travel
            return .cursor(x: x, y: y, click: tokens.contains("click"), glideMs: max(0, glide))
        }
        if tokens.contains("ui") {
            // demotape://ui/dump?app=Safari
            if tokens.contains("dump") { return .dumpUI(app: q["app"]) }
            // Semantic targeting: demotape://ui/click?label=Export&role=AXButton&app=Safari
            // (or ui/find to only publish the rect). Beats coordinates: it survives a moved window
            // and reports honestly when the element isn't there.
            if tokens.contains("click") || tokens.contains("find") {
                guard let label = q["label"], !label.isEmpty else { return nil }
                let query = UIQuery.Query(label: label,
                                          role: q["role"],
                                          app: q["app"],
                                          index: Int(q["index"] ?? "") ?? 0)
                return .element(query: query, click: tokens.contains("click"))
            }
            // demotape://ui/open?window=about  — or the shorthand demotape://ui/about
            let named = q["window"]?.lowercased() ?? tokens.last
            guard let named = named, let win = Window(rawValue: named) else { return nil }
            let hold = Int(dbl("hold") ?? dbl("holdms") ?? 0)
            return .openUI(win, holdMs: max(0, hold))
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
    /// `menuBarButton` (when known) is the screen rect of DemoTape's menu-bar icon in top-left
    /// origin points, so an orchestrator can click it to film the menu — there's no other way to
    /// find a menu-bar extra's position from outside the app.
    /// `window` (when known) is the screen rect of the window most recently opened through
    /// `ui/open`, in the same top-left origin points the cursor commands take. A scripted
    /// walkthrough needs this to aim: windows are centred by AppKit, so guessing their position
    /// risks landing an "emphasis" click on a real button.
    /// Result of the most recent semantic lookup, so a script can confirm what it hit — or that it
    /// missed, which it must treat as a failure rather than clicking blindly.
    struct ElementStatus {
        var role: String
        var label: String
        var frame: CGRect
        var found: Bool
    }

    static func writeStatus(state: String, lastOutput: String? = nil,
                            menuBarButton: CGRect? = nil, window: CGRect? = nil,
                            element: ElementStatus? = nil) {
        var dict: [String: Any] = [
            "state": state,
            "recording": (state == "recording"),
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let lastOutput = lastOutput { dict["lastOutput"] = lastOutput }
        if let r = menuBarButton {
            dict["menuBarButton"] = ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height,
                                     "centerX": r.midX, "centerY": r.midY]
        }
        if let r = window {
            dict["window"] = ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height,
                              "centerX": r.midX, "centerY": r.midY]
        }
        if let e = element {
            dict["element"] = ["found": e.found, "role": e.role, "label": e.label,
                               "x": e.frame.minX, "y": e.frame.minY,
                               "w": e.frame.width, "h": e.frame.height,
                               "centerX": e.frame.midX, "centerY": e.frame.midY]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else { return }
        try? data.write(to: statusURL, options: .atomic)
    }
}
