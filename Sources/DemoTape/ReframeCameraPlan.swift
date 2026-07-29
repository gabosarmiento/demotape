import CoreGraphics
import Foundation

/// A **planned** camera for vertical/social reframing.
///
/// The styled render's auto-zoom is reactive: it chases the focus point frame by frame, which is fine
/// in landscape (where the whole width is visible anyway) but reads as drift and micro-adjustment in a
/// narrow portrait window. So a reframe is *planned* instead: the whole event timeline is read up
/// front and turned into a list of keyframes — camera states with the time they must be reached — and
/// each frame simply interpolates that plan. Because planning happens ahead of the render, the camera
/// can **anticipate**: a move completes exactly at the interaction it belongs to, so the camera has
/// already arrived when the click or the keystroke lands.
///
/// The behaviours it encodes:
/// - **Overview** (`zoom == 1`, whole source width, letterboxed) is the resting state. Idle stretches
///   and fast scrolling return to it.
/// - **Interaction** shots zoom to the fill zoom (crop the sides, keep the full height).
/// - **Holds**: interactions close together in the same area are one shot, so the camera doesn't
///   twitch between neighbouring clicks.
/// - **Text follows like a text editor**: a typing run is framed left-aligned so the sentence grows
///   rightward into the frame, and the window only advances once the caret nears its right edge.
/// - **Distant pans route through overview**: a far jump zooms out, moves, and zooms back in, instead
///   of sliding across the screen at high zoom.
///
/// Pure and unit-tested: no pixels, no I/O. Clamping to the source lives in `ReframeGeometry.view`.
struct ReframeCameraPlan {

    /// A camera state: zoom (1 = whole source width) and the normalized centre it looks at.
    struct State: Equatable {
        var zoom: CGFloat
        var cx: CGFloat
        var cy: CGFloat
        static let overview = State(zoom: 1, cx: 0.5, cy: 0.5)
        var isOverview: Bool { zoom <= 1.001 }
    }

    /// The camera must be at `state` by time `t`.
    struct Keyframe: Equatable {
        var t: Double
        var state: State
    }

    /// Tunables. Defaults are the values the behaviour was specified with.
    struct Params {
        /// Zoom used for interaction shots. Normally `ReframeGeometry.fillZoom`.
        var interactionZoom: CGFloat = 3.0
        /// Seconds a move takes; it *ends* on the keyframe so the camera arrives on the beat.
        var transition: Double = 0.6
        /// How long a click keeps the camera before it can leave.
        var clickHold: Double = 1.6
        /// How long the camera stays after the last keystroke of a run.
        var typeTail: Double = 1.2
        /// A gap longer than this starts a new typing run.
        var typingRunGap: Double = 1.5
        /// Beats closer than this merge when they're in the same area.
        var mergeGap: Double = 0.7
        /// "Same area": horizontal distance, as a fraction of source width.
        var sameArea: CGFloat = 0.15
        /// Further than this and the move routes through overview instead of panning.
        var distantPan: CGFloat = 0.40
        /// No interaction for this long → ease back to overview.
        var idleReturn: Double = 2.5
        /// Where the caret sits in the window when a typing run starts (fraction of the window):
        /// small, so the sentence has the rest of the window to grow into.
        var typingLeftPad: CGFloat = 0.12
        /// The caret pushes the window along once it passes this fraction of the window.
        var typingRightEdge: CGFloat = 0.82
        /// Don't emit a new keyframe for a smaller centre change than this (anti-micro-adjust).
        var minCentreShift: CGFloat = 0.035
        /// A scroll burst (this many samples inside `scrollBurstWindow`) counts as fast scrolling.
        var scrollBurstCount = 4
        var scrollBurstWindow: Double = 0.6
    }

    let keyframes: [Keyframe]
    let params: Params

    // MARK: - Evaluation

    /// The camera state at `t`: hold the previous keyframe, then ease so the next one is reached
    /// exactly on time. Eased with smoothstep — continuous, and never a teleport.
    func state(at t: Double) -> State {
        guard let first = keyframes.first else { return .overview }
        if keyframes.count == 1 || t <= first.t { return first.state }
        guard let last = keyframes.last else { return .overview }
        if t >= last.t { return last.state }

        var i = 0
        for (idx, kf) in keyframes.enumerated() where kf.t <= t { i = idx }
        guard i + 1 < keyframes.count else { return keyframes[i].state }
        let a = keyframes[i], b = keyframes[i + 1]
        let gap = b.t - a.t
        guard gap > 0 else { return b.state }
        let move = min(params.transition, max(0.15, gap))
        let start = b.t - move                       // arrive exactly on the beat
        if t <= start { return a.state }             // hold until the move begins
        let p = CGFloat(smoothstep((t - start) / move))
        return State(zoom: a.state.zoom + (b.state.zoom - a.state.zoom) * p,
                     cx: a.state.cx + (b.state.cx - a.state.cx) * p,
                     cy: a.state.cy + (b.state.cy - a.state.cy) * p)
    }

    /// A short label for the debug overlay ("overview" / "shot z3.5").
    func label(at t: Double) -> String {
        let s = state(at: t)
        return s.isOverview ? "overview" : String(format: "shot z%.1f", Double(s.zoom))
    }

    // MARK: - Planning

    /// A stretch of the timeline the camera treats as one shot.
    private struct Beat {
        var start: Double
        var end: Double
        /// Positions of interest inside the beat, in time order (a click is one; a typing run is many).
        var samples: [(t: Double, x: CGFloat, y: CGFloat)]
        /// Fast scrolling and other "show me everything" stretches stay at overview.
        var overview: Bool = false
    }

    /// Build a plan from a recording's events.
    static func build(metadata: RecordingMetadata, duration: Double, params: Params) -> ReframeCameraPlan {
        var beats = interactionBeats(metadata: metadata, params: params)
        beats = merge(beats, params: params)
        beats = addScrollOverviews(beats, scrolls: metadata.scrolls, params: params)

        let window = 1 / max(1, params.interactionZoom)     // fraction of source width visible
        var kfs: [Keyframe] = [Keyframe(t: 0, state: .overview)]
        var lastEnd: Double?
        var lastState: State?

        for beat in beats {
            let beatKfs = beat.overview
                ? [Keyframe(t: beat.start, state: .overview)]
                : keyframes(for: beat, window: window, params: params)
            guard let firstKf = beatKfs.first else { continue }

            // Route through overview when the timeline went quiet, or when the move is a long pan.
            let idle = lastEnd.map { beat.start - $0 >= params.idleReturn } ?? false
            let distant = (lastState.map { !$0.isOverview } ?? false)
                && !firstKf.state.isOverview
                && abs(firstKf.state.cx - (lastState?.cx ?? 0)) > params.distantPan
            if (idle || distant), let from = lastEnd, !firstKf.state.isOverview {
                let latest = firstKf.t - params.transition - 0.05
                let at = idle ? min(from + 0.9, latest) : (from + firstKf.t) / 2
                if at > from + 0.05, at < firstKf.t - 0.05 {
                    kfs.append(Keyframe(t: at, state: .overview))
                }
            }

            kfs.append(contentsOf: beatKfs)
            if let tail = beatKfs.last, beat.end > tail.t + 0.05 {
                kfs.append(Keyframe(t: beat.end, state: tail.state))   // hold to the end of the shot
            }
            lastEnd = max(beat.end, beatKfs.last?.t ?? beat.end)
            lastState = beatKfs.last?.state
        }

        // Return to overview at the end if the recording keeps running.
        if let end = lastEnd, let s = lastState, !s.isOverview, duration - end >= params.idleReturn {
            kfs.append(Keyframe(t: min(end + 0.9, duration), state: .overview))
        }

        return ReframeCameraPlan(keyframes: monotonic(kfs), params: params)
    }

    /// Clicks and typing runs, in time order.
    private static func interactionBeats(metadata: RecordingMetadata, params: Params) -> [Beat] {
        var beats: [Beat] = []

        // Typing runs: consecutive keystrokes, split on a long gap. A run is one shot whose window
        // scrolls with the caret.
        let keys = metadata.keys.sorted { $0.t < $1.t }
        var run: [KeySample] = []
        func flushRun() {
            guard let first = run.first, let last = run.last else { return }
            // Caret positions when the recorder knows them; otherwise the run has no position of its
            // own and is left to the click that focused the field.
            var samples: [(t: Double, x: CGFloat, y: CGFloat)] = []
            var furthest = -CGFloat.greatestFiniteMagnitude
            for k in run {
                guard let kx = k.x, let ky = k.y else { continue }
                let x = CGFloat(kx)
                if x > furthest { furthest = x }     // text only grows rightward within a run
                samples.append((k.t, furthest, CGFloat(ky)))
            }
            if !samples.isEmpty {
                beats.append(Beat(start: first.t, end: last.t + params.typeTail, samples: samples))
            }
            run = []
        }
        for k in keys {
            if let prev = run.last, k.t - prev.t > params.typingRunGap { flushRun() }
            run.append(k)
        }
        flushRun()

        // Clicks.
        for c in metadata.clicks.sorted(by: { $0.t < $1.t }) {
            beats.append(Beat(start: c.t, end: c.t + params.clickHold,
                              samples: [(c.t, CGFloat(c.x), CGFloat(c.y))]))
        }

        return beats.sorted { $0.start < $1.start }
    }

    /// Fold beats that are close in time and in the same area into one shot, so neighbouring clicks
    /// (and the click that opens a field followed by typing in it) don't each yank the camera.
    private static func merge(_ beats: [Beat], params: Params) -> [Beat] {
        var out: [Beat] = []
        for beat in beats {
            guard var last = out.last,
                  let lastX = last.samples.last?.x,
                  let nextX = beat.samples.first?.x else { out.append(beat); continue }
            let close = beat.start - last.end < params.mergeGap
            let sameArea = abs(nextX - lastX) < params.sameArea
            if close && sameArea {
                last.samples.append(contentsOf: beat.samples)
                last.end = max(last.end, beat.end)
                out[out.count - 1] = last
            } else {
                out.append(beat)
            }
        }
        return out
    }

    /// Add overview stretches for fast scrolling, where no single point is the subject.
    private static func addScrollOverviews(_ beats: [Beat], scrolls: [ScrollSample],
                                           params: Params) -> [Beat] {
        guard scrolls.count >= params.scrollBurstCount else { return beats }
        let sorted = scrolls.sorted { $0.t < $1.t }
        var bursts: [(Double, Double)] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1].t - sorted[i].t <= params.scrollBurstWindow { j += 1 }
            if j - i + 1 >= params.scrollBurstCount {
                let start = sorted[i].t, end = sorted[j].t + 0.4
                if var lastBurst = bursts.last, start <= lastBurst.1 {
                    lastBurst.1 = max(lastBurst.1, end); bursts[bursts.count - 1] = lastBurst
                } else {
                    bursts.append((start, end))
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        var out = beats
        for b in bursts {
            // Skip a burst that happens inside an interaction shot — the interaction wins.
            let overlaps = beats.contains { $0.start < b.1 && b.0 < $0.end }
            if !overlaps {
                out.append(Beat(start: b.0, end: b.1, samples: [], overview: true))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Keyframes inside one interaction shot.
    ///
    /// A single position is simply framed on (clamping at the source edges is what makes an
    /// edge element sit near the edge of the frame rather than centred). A run of positions — typing —
    /// is framed like a text editor: the window starts with the caret near its left so the sentence
    /// grows rightward into view, and only advances once the caret reaches the right edge.
    private static func keyframes(for beat: Beat, window: CGFloat, params: Params) -> [Keyframe] {
        guard let first = beat.samples.first else { return [] }
        let zoom = params.interactionZoom
        if beat.samples.count == 1 {
            return [Keyframe(t: beat.start, state: State(zoom: zoom, cx: first.x, cy: first.y))]
        }

        var out: [Keyframe] = []
        var origin = min(max(first.x - params.typingLeftPad * window, 0), 1 - window)
        var lastCx: CGFloat?
        for s in beat.samples {
            if s.x > origin + params.typingRightEdge * window {
                origin = s.x - params.typingRightEdge * window
            } else if s.x < origin + params.typingLeftPad * window * 0.7 {
                origin = s.x - params.typingLeftPad * window
            }
            origin = min(max(origin, 0), max(0, 1 - window))
            let cx = origin + window / 2
            // Emit only meaningful moves: a keyframe per keystroke would be a vibration, not a pan.
            if let l = lastCx, abs(cx - l) < params.minCentreShift { continue }
            let t = out.isEmpty ? beat.start : s.t
            out.append(Keyframe(t: t, state: State(zoom: zoom, cx: cx, cy: s.y)))
            lastCx = cx
        }
        if out.isEmpty {
            out = [Keyframe(t: beat.start, state: State(zoom: zoom, cx: first.x, cy: first.y))]
        }
        return out
    }

    /// Keep times strictly increasing (later keyframes win on a tie) so evaluation is well-defined.
    private static func monotonic(_ kfs: [Keyframe]) -> [Keyframe] {
        var out: [Keyframe] = []
        for kf in kfs.sorted(by: { $0.t < $1.t }) {
            if let last = out.last, kf.t <= last.t + 0.001 {
                out[out.count - 1] = Keyframe(t: last.t, state: kf.state)
            } else {
                out.append(kf)
            }
        }
        return out
    }
}

private func smoothstep(_ x: Double) -> Double {
    let c = min(max(x, 0), 1)
    return c * c * (3 - 2 * c)
}
