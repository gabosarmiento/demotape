import Foundation

/// The **AI Director** — turns a recording's event stream (clicks, typing, scrolls) into a
/// paced edit `Timeline`, the way a live TV director cuts between cameras to hold attention.
///
/// Core idea: **cut on the rhythm of the work, never mid-action.**
/// - While the person is actively clicking/typing, stay on the **screen** (that's the detail
///   they're showing) with gentle motion.
/// - When they pause (a calm gap with no input) and a webcam exists, cut to the **presenter**
///   for a talking-head beat, then cut back when activity resumes.
/// - Continuous slow zoom keeps every shot alive without ever cutting on a click.
///
/// Output is the same `Timeline`/`EditEvent` model the `TemplateComposer` renders, so the
/// composer handles the actual layout switching (screen ↔ full webcam) and zoom.
enum AutoDirector {

    struct Params {
        /// A pause at least this long (seconds) with no input is a chance to cut to the presenter.
        var minCalmGap: Double = 3.0
        /// Don't linger on the presenter longer than this (shots should breathe, then move on).
        var maxWebcamShot: Double = 6.0
        /// Keep at least this long between/around webcam cuts (rhythm; avoids flapping).
        var minScreenRun: Double = 5.0
        /// A webcam cut must be at least this long to be worth it.
        var minWebcamShot: Double = 2.5
        /// Gentle Ken-Burns push-in applied to the (static) webcam shot.
        var webcamZoom: CGFloat = 1.14
        /// Subtle left→right pan fraction on the webcam shot. Positive = left→right (the
        /// direction audiences read as natural). Never right→left.
        var webcamPan: CGFloat = 0.12
    }

    /// Builds the director timeline from recorded activity.
    ///
    /// Design (learned the hard way): the styled master **already** carries the click-following
    /// auto-zoom, which looks good on its own. The director must not fight it — so it adds **no**
    /// zoom to the screen. Its job is purely the parts the auto-zoom can't do: switch to the
    /// presenter during pauses, and give that static webcam shot a little life (a slow push-in +
    /// a subtle left→right pan). On the cut back to the screen, zoom resets to 1× (the cut hides
    /// the reset), so the screen is never left zoomed.
    static func plan(metadata: RecordingMetadata, hasWebcam: Bool, params: Params = Params()) -> Timeline {
        let duration = max(0.5, metadata.duration)
        var tl = Timeline(events: [])

        // Bookend with a fade in and a fade to black.
        tl.add(0, min(0.6, duration * 0.3), .fadeIn, .easeOut)
        tl.add(max(0, duration - 0.9), min(0.9, duration * 0.3), .fadeToBlack, .easeIn)

        // No webcam → nothing to cut to; let the styled master's auto-zoom carry the whole clip.
        guard hasWebcam else { return tl }

        let segments = calmGapSegments(metadata: metadata, duration: duration, params: params)
        return timeline(webcamSegments: segments, duration: duration, params: params)
    }

    /// Presenter (webcam) shots derived from calm gaps — the local, no-network heuristic.
    static func calmGapSegments(metadata: RecordingMetadata, duration: Double,
                                params: Params = Params()) -> [(start: Double, end: Double)] {
        var out = [(start: Double, end: Double)]()
        var lastBack = 0.0
        for gap in calmGaps(metadata: metadata, duration: duration, minGap: params.minCalmGap) {
            let camStart = gap.start + 0.4
            let camEnd = min(gap.end - 0.2, camStart + params.maxWebcamShot)
            guard camStart >= params.minScreenRun,
                  camStart - lastBack >= params.minScreenRun,
                  camEnd - camStart >= params.minWebcamShot else { continue }
            out.append((camStart, camEnd))
            lastBack = camEnd
        }
        return out
    }

    /// Builds the full edit timeline from a set of presenter (webcam) shots — shared by the
    /// local director and the AI director. Each shot cuts to the webcam with a gentle Ken Burns
    /// (slow push-in + subtle left→right pan) and resets zoom to 1× on the cut back so the screen
    /// never double-zooms against the baked-in auto-zoom.
    static func timeline(webcamSegments segments: [(start: Double, end: Double)],
                         duration: Double, params: Params = Params()) -> Timeline {
        let duration = max(0.5, duration)
        var tl = Timeline(events: [])
        tl.add(0, min(0.6, duration * 0.3), .fadeIn, .easeOut)
        tl.add(max(0, duration - 0.9), min(0.9, duration * 0.3), .fadeToBlack, .easeIn)

        for seg in segments {
            let start = max(0, seg.start)
            let end = min(duration, seg.end)
            let dur = end - start
            guard dur >= params.minWebcamShot else { continue }
            tl.add(start, 0.01, .switchAngle(.webcam))
            tl.add(end, 0.01, .switchAngle(.screen))
            tl.add(start, dur, .zoomIn(params.webcamZoom), .easeInOut)
            tl.add(start, dur, .pan(params.webcamPan, 0), .easeInOut)   // positive = left→right
            tl.add(end, 0.01, .zoomIn(1.0))
        }
        return tl
    }

    /// Cleans an unordered/overlapping set of presenter shots (e.g. from the AI) into a
    /// well-spaced, rhythmically valid sequence.
    static func sanitize(_ segments: [(start: Double, end: Double)], duration: Double,
                         params: Params = Params()) -> [(start: Double, end: Double)] {
        let sorted = segments
            .map { (start: max(0, min($0.start, $0.end)), end: min(duration, max($0.start, $0.end))) }
            .sorted { $0.start < $1.start }
        var out = [(start: Double, end: Double)]()
        var lastBack = 0.0
        for var seg in sorted {
            seg.end = min(seg.end, seg.start + params.maxWebcamShot)
            guard seg.start >= params.minScreenRun,
                  seg.start - lastBack >= params.minScreenRun,
                  seg.end - seg.start >= params.minWebcamShot else { continue }
            out.append(seg)
            lastBack = seg.end
        }
        return out
    }

    /// Stretches of `duration` with no click/keystroke/scroll for at least `minGap` seconds.
    static func calmGaps(metadata: RecordingMetadata, duration: Double, minGap: Double) -> [(start: Double, end: Double)] {
        var times = [Double]()
        times.append(contentsOf: metadata.clicks.map { $0.t })
        times.append(contentsOf: metadata.keys.map { $0.t })
        times.append(contentsOf: metadata.scrolls.map { $0.t })
        times.sort()

        var gaps = [(start: Double, end: Double)]()
        var prev = 0.0
        for t in times {
            if t - prev >= minGap { gaps.append((prev, t)) }
            prev = max(prev, t)
        }
        if duration - prev >= minGap { gaps.append((prev, duration)) }
        return gaps
    }
}
