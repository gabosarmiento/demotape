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
    /// Internal rather than private so the typing-pan behaviour can be tested directly: `target(at:)`
    /// additionally clamps the frame inside the video bounds, which hides what the anchor is doing.
    func focusAnchor(at t: Double) -> (x: CGFloat, y: CGFloat) {
        let lastClick = clicks.last(where: { $0.t <= t })
        let lastKey = keys.last(where: { $0.t <= t })

        let typing = lastKey != nil
            && (lastClick == nil || lastKey!.t >= lastClick!.t)
            && (t - lastKey!.t) < typeHold

        if typing {
            // Follow the caret when the recorder knows where it is: a long sentence grows sideways,
            // and holding on the click that focused the field would let the words leave a zoomed
            // frame mid-thought.
            //
            // Two guards make the pan smooth. Reported positions can arrive out of order and repeat
            // (a driver may report in overlapping batches), and taking "the latest sample" then makes
            // the anchor jump backwards and forwards every frame — which looks like a vibration
            // rather than a pan. So: take the furthest caret reached so far (text only grows), and
            // ease towards it instead of snapping.
            if let target = furthestCaret(upTo: t) {
                return target
            }
            if let c = lastClick {
                return (CGFloat(c.x), CGFloat(c.y))  // hold on the text field
            }
        }
        if let c = lastClick, (t - c.t) < clickHold {
            return (CGFloat(c.x), CGFloat(c.y))  // hold on the last click
        }
        let cur = cursorPosition(at: t)
        return (cur.x, cur.y)                     // otherwise follow the cursor
    }

    /// The caret anchor for typing at time `t`: the furthest point reached within the current typing
    /// run, eased so the camera pans rather than snaps.
    ///
    /// Positions are reported per keystroke-batch, which means duplicates and out-of-order arrivals.
    /// Using the most recent sample makes the anchor oscillate between two nearby x values every
    /// frame — a vibration, not a pan. Text only ever grows rightwards within a run, so the furthest
    /// position is the honest target, and easing towards it keeps the motion continuous.
    private func furthestCaret(upTo t: Double) -> (x: CGFloat, y: CGFloat)? {
        // Only consider the current run: a gap longer than the hold means a new field/sentence.
        var runStart = 0.0
        var previous: Double?
        for k in keys where k.t <= t {
            if let p = previous, k.t - p > typeHold { runStart = k.t }
            previous = k.t
        }
        let positioned = keys.filter { $0.t <= t && $0.t >= runStart && $0.x != nil && $0.y != nil }
        guard !positioned.isEmpty else { return nil }

        // Make the series monotonic first (running maximum): text only grows rightwards within a
        // run, so a lower x arriving later is a stale report, not the caret moving back.
        var monotonic: [(t: Double, x: CGFloat, y: CGFloat)] = []
        var furthestX = -CGFloat.greatestFiniteMagnitude
        var furthestY: CGFloat = 0
        for k in positioned {
            let kx = CGFloat(k.x!), ky = CGFloat(k.y!)
            if kx > furthestX { furthestX = kx; furthestY = ky }
            monotonic.append((k.t, furthestX, furthestY))
        }

        // Then low-pass it. An exponential time kernel is continuous in `t`, so the anchor eases
        // between reports instead of stepping to each new one — a step every heartbeat is what read
        // as vibration. Tau is short enough to keep up with fast typing, long enough to smooth it.
        let tau = 0.45
        var weightSum = 0.0, xSum = 0.0, ySum = 0.0
        for sample in monotonic {
            let weight = exp(-(t - sample.t) / tau)
            weightSum += weight
            xSum += Double(sample.x) * weight
            ySum += Double(sample.y) * weight
        }
        guard weightSum > 0 else { return (furthestX, furthestY) }
        return (CGFloat(xSum / weightSum), CGFloat(ySum / weightSum))
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

    /// Which pointer shape was on screen at `t`.
    ///
    /// Uses the last sample at or before `t` — the shape is a step function (it changes the instant
    /// the pointer crosses a control), so interpolating it would be meaningless. Sidecars recorded
    /// before shapes were captured report none, and render as an arrow.
    func cursorKind(at t: Double) -> CursorKind {
        guard let sample = cursor.last(where: { $0.t <= t }) ?? cursor.first else {
            return .arrow
        }
        return CursorKind(rawValueOrArrow: sample.kind)
    }

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
