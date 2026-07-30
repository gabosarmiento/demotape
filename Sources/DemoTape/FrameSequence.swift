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

    /// Declared output size, when the manifest states one and it's usable.
    var declaredSize: CGSize? {
        guard let w = width, let h = height, w >= 2, h >= 2 else { return nil }
        return CGSize(width: w, height: h)
    }
}
