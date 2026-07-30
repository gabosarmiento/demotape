import CoreGraphics
import Foundation

/// A captured sequence of still frames plus the moment each was shown — the input to
/// `--encode-frames`.
///
/// Why this exists: a coding agent driving a browser can capture frames over the DevTools protocol
/// (`Page.startScreencast`) without any screen-recording permission, but that gives JPEGs, not a
/// video. Encoding them here means the whole agentic path — record, style, verify — works on a machine
/// where DemoTape was never granted Screen Recording, and the capture half is no longer macOS-only.
///
/// The manifest is deliberately dumb: paths and timestamps. Everything expressive (zoom, cursor,
/// clicks) comes from the `events.json` sidecar the driver writes alongside it, exactly as it does for
/// a real screen capture — so `--render` can't tell the difference.
///
/// ```jsonc
/// {
///   "width": 1280,          // optional; inferred from the first frame when absent
///   "height": 800,
///   "fps": 30,              // optional; only used to synthesize timestamps if `t` is missing
///   "frames": [
///     { "path": "0001.jpg", "t": 0.000 },
///     { "path": "0002.jpg", "t": 0.033 }
///   ]
/// }
/// ```
struct FrameSequence: Decodable {
    var width: Double?
    var height: Double?
    var fps: Double?
    /// Total length of the capture, when the capturer knows it.
    ///
    /// This is **not** the same as the last frame's timestamp, and the difference is a bug you can
    /// see. A screencast only emits a frame when something repaints, so after the final visible change
    /// no more frames arrive even though the capture is still running. Ending the video at the last
    /// frame therefore cuts off exactly the beat where the result sits on screen — and any narration
    /// laid over that stretch runs past the end of the video.
    var duration: Double?
    var frames: [Frame]

    struct Frame: Decodable {
        var path: String
        /// Seconds from the start of the capture. Optional: sequences that arrive at a fixed rate can
        /// omit it and let `fps` synthesize the timeline.
        var t: Double?
    }

    /// A frame resolved to an absolute URL and a definite time.
    struct Resolved: Equatable {
        var url: URL
        var t: Double
    }

    /// Resolve the manifest against the directory it lives in, and produce a clean, strictly
    /// increasing timeline.
    ///
    /// Screencast frames are delivered as they're produced, which means duplicate and slightly
    /// out-of-order timestamps are normal rather than exceptional. An encoder that appends those
    /// verbatim fails (a writer rejects a non-increasing presentation time), so normalizing is part of
    /// reading the manifest, not an optional cleanup step.
    func resolve(relativeTo directory: URL) -> [Resolved] {
        let rate = (fps ?? 30) > 0 ? (fps ?? 30) : 30
        var out: [Resolved] = []
        for (i, frame) in frames.enumerated() {
            let url = frame.path.hasPrefix("/")
                ? URL(fileURLWithPath: frame.path)
                : directory.appendingPathComponent(frame.path)
            let t = frame.t ?? (Double(i) / rate)
            guard t.isFinite, t >= 0 else { continue }
            // Enforce a strictly increasing timeline: nudge anything that didn't advance to just
            // after its predecessor rather than dropping it, so no captured frame is lost.
            if let last = out.last {
                out.append(Resolved(url: url, t: max(t, last.t + 1 / (rate * 4))))
            } else {
                out.append(Resolved(url: url, t: t))
            }
        }
        return out
    }

    /// The same frames laid out at a **constant** rate, holding each image until the next one arrives.
    ///
    /// This matters because a screencast only emits a frame when the page actually repaints. A mostly
    /// static page can produce three or four frames a second, and since the renderer draws one output
    /// frame per source frame it cannot invent the ones in between — so the synthetic cursor would move
    /// only a few times a second and read as a stutter, even though the capture was perfectly good.
    ///
    /// Holding the last image at a fixed cadence turns the capture into an ordinary constant-rate
    /// video. Repeated identical frames cost almost nothing in H.264 (they encode as skips), and the
    /// cursor, zoom and captions are all drawn per output frame, so they become smooth.
    func heldTimeline(relativeTo directory: URL, rate: Double) -> [Resolved] {
        let captured = resolve(relativeTo: directory)
        guard rate > 0, let first = captured.first, let last = captured.last else { return captured }
        let step = 1 / rate
        // Run to the end of the CAPTURE, not to the last frame, holding the final image — otherwise the
        // closing beat (the result sitting on screen, the narration tail) is simply missing.
        let end = max(last.t, duration ?? last.t)
        let span = end - first.t
        guard span > 0, Double(captured.count) < span * rate else { return captured }

        // Derive each slot's time from its index rather than accumulating `+= step`: accumulating
        // drifts, and a final slot that lands at 0.99999997 instead of 1.0 silently misses the last
        // captured frame.
        let slots = Int((span / step).rounded()) + 1
        let epsilon = step / 1000
        var out: [Resolved] = []
        var index = 0
        for i in 0..<slots {
            let t = first.t + Double(i) * step
            // Advance to the newest frame at or before `t`.
            while index + 1 < captured.count, captured[index + 1].t <= t + epsilon { index += 1 }
            out.append(Resolved(url: captured[index].url, t: t))
        }
        return out
    }

    /// Declared output size, when the manifest states one and it's usable.
    var declaredSize: CGSize? {
        guard let w = width, let h = height, w >= 2, h >= 2 else { return nil }
        return CGSize(width: w, height: h)
    }
}
