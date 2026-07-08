import Foundation
import CoreGraphics

/// Computes the auto-zoom "camera" over time from the captured event timeline.
///
/// Zoom is driven by *activity*: clicks and typing both keep the camera zoomed.
/// The focus center anchors to the most recent click (so while you type, the view
/// stays locked on the field you clicked into — "text input tracking" — instead of
/// zooming out), and follows the cursor otherwise. Temporal smoothing (a spring) is
/// applied by the renderer across frames.
///
/// Modeled on Screenize's per-activity zoom planning.
struct FocusTimeline {
    private let clicks: [ClickSample]
    private let cursor: [CursorSample]
    private let keys: [KeySample]

    let maxZoom: CGFloat

    // Click zoom window
    private let clickRampIn = 0.4
    private let clickHold = 1.6
    private let clickRampOut = 0.8
    // Typing keeps the zoom alive; each key extends this window.
    private let typeRampIn = 0.12
    private let typeHold = 1.5
    private let typeRampOut = 0.7

    init(metadata: RecordingMetadata, maxZoom: CGFloat = 2.0) {
        self.clicks = metadata.clicks.sorted { $0.t < $1.t }
        self.cursor = metadata.cursor.sorted { $0.t < $1.t }
        self.keys = metadata.keys.sorted { $0.t < $1.t }
        self.maxZoom = maxZoom
    }

    /// Activity level 0...1 at time t.
    func activity(at t: Double) -> Double {
        var a = 0.0
        for c in clicks {
            a = max(a, bump(t - c.t, rampIn: clickRampIn, hold: clickHold, rampOut: clickRampOut))
            if a >= 1 { return 1 }
        }
        for k in keys {
            a = max(a, bump(t - k.t, rampIn: typeRampIn, hold: typeHold, rampOut: typeRampOut))
            if a >= 1 { return 1 }
        }
        return a
    }

    func target(at t: Double) -> (scale: CGFloat, cx: CGFloat, cy: CGFloat) {
        let a = CGFloat(activity(at: t))
        let scale = 1.0 + a * (maxZoom - 1.0)

        let anchor = focusAnchor(at: t)
        var cx = 0.5 + a * (anchor.x - 0.5)
        var cy = 0.5 + a * (anchor.y - 0.5)

        let half = 0.5 / scale
        cx = min(max(cx, half), 1 - half)
        cy = min(max(cy, half), 1 - half)
        return (scale, cx, cy)
    }

    /// Where the camera should look: the field/point being worked on.
    /// While typing, this is the last click (the input the user focused); otherwise
    /// it tracks the cursor.
    private func focusAnchor(at t: Double) -> (x: CGFloat, y: CGFloat) {
        let lastClick = clicks.last(where: { $0.t <= t })
        let lastKey = keys.last(where: { $0.t <= t })

        let typing = lastKey != nil
            && (lastClick == nil || lastKey!.t >= lastClick!.t)
            && (t - lastKey!.t) < typeHold

        if typing, let c = lastClick {
            return (CGFloat(c.x), CGFloat(c.y))  // hold on the text field
        }
        if let c = lastClick, (t - c.t) < clickHold {
            return (CGFloat(c.x), CGFloat(c.y))  // hold on the last click
        }
        let cur = cursorPosition(at: t)
        return (cur.x, cur.y)                     // otherwise follow the cursor
    }

    /// Active keyboard-shortcut badge (e.g. "⌘⇧D") at time t, or nil. Only shortcuts
    /// (with ⌘/⌃/⌥) are shown — plain typing produces no badge.
    func shortcutBadge(at t: Double, window: Double = 1.1) -> String? {
        for k in keys.reversed() where k.t <= t {
            if t - k.t > window { break }
            if isShortcut(k) { return Self.badgeLabel(for: k) }
        }
        return nil
    }

    private func isShortcut(_ k: KeySample) -> Bool {
        k.modifiers.contains("cmd") || k.modifiers.contains("ctrl") || k.modifiers.contains("opt")
    }

    static func badgeLabel(for k: KeySample) -> String {
        var s = ""
        if k.modifiers.contains("ctrl") { s += "⌃" }
        if k.modifiers.contains("opt") { s += "⌥" }
        if k.modifiers.contains("shift") { s += "⇧" }
        if k.modifiers.contains("cmd") { s += "⌘" }
        let key = keyName(code: k.keyCode, chars: k.chars)
        return s + key
    }

    private static func keyName(code: Int, chars: String) -> String {
        switch code {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "esc"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        default:
            let c = chars.trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? "?" : c.uppercased()
        }
    }

    // MARK: - Helpers

    private func bump(_ dt: Double, rampIn: Double, hold: Double, rampOut: Double) -> Double {
        if dt < 0 {
            return dt > -rampIn ? smoothstep((dt + rampIn) / rampIn) : 0
        } else if dt <= hold {
            return 1
        } else if dt <= hold + rampOut {
            return 1 - smoothstep((dt - hold) / rampOut)
        }
        return 0
    }

    /// Public interpolated cursor position at t (normalized, top-left).
    func cursorPoint(at t: Double) -> (x: CGFloat, y: CGFloat) { cursorPosition(at: t) }

    private func cursorPosition(at t: Double) -> (x: CGFloat, y: CGFloat) {
        guard !cursor.isEmpty else { return (0.5, 0.5) }
        if t <= cursor.first!.t { return (CGFloat(cursor.first!.x), CGFloat(cursor.first!.y)) }
        if t >= cursor.last!.t { return (CGFloat(cursor.last!.x), CGFloat(cursor.last!.y)) }
        var lo = 0, hi = cursor.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cursor[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        let b = cursor[lo]
        let a = cursor[max(0, lo - 1)]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        return (CGFloat(a.x + (b.x - a.x) * f), CGFloat(a.y + (b.y - a.y) * f))
    }

    private func smoothstep(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
