import CoreGraphics
import Foundation

/// Pure geometry for `--reframe`: target sizes, and turning a camera state (zoom + centre) into the
/// rectangle actually sampled from the source plus where it lands in the output frame.
///
/// The invariant everything else depends on: **the sampled rect never extends past any edge of the
/// source frame.** It is clamped on both axes every frame, after any interpolation. The visible
/// consequence is deliberate — a click at the far right slides the camera until its right edge meets
/// the source's right edge and stops, so the element appears near the right of the phone frame rather
/// than centred, and no frame ever samples outside the image.
enum ReframeGeometry {

    /// Resolve a target spec into an output size. Accepts a known ratio ("9:16", "1:1", "4:5",
    /// "16:9", "5:4"), an explicit "WxH" (e.g. "1080x1920"), or an arbitrary "W:H" (normalized so the
    /// short side is 1080). Returns nil if it can't be parsed.
    static func targetSize(for spec: String) -> CGSize? {
        let s = spec.lowercased().replacingOccurrences(of: " ", with: "")
        let known: [String: CGSize] = [
            "9:16": CGSize(width: 1080, height: 1920),
            "16:9": CGSize(width: 1920, height: 1080),
            "1:1":  CGSize(width: 1080, height: 1080),
            "4:5":  CGSize(width: 1080, height: 1350),
            "5:4":  CGSize(width: 1350, height: 1080),
        ]
        if let sz = known[s] { return sz }
        // Explicit pixels: WxH.
        let x = s.split(separator: "x")
        if x.count == 2, let w = Int(x[0]), let h = Int(x[1]), w > 0, h > 0 {
            return CGSize(width: w, height: h)
        }
        // Arbitrary ratio W:H → 1080 on the short side.
        let c = s.split(separator: ":")
        if c.count == 2, let w = Double(c[0]), let h = Double(c[1]), w > 0, h > 0 {
            return h >= w ? CGSize(width: 1080, height: (1080 * h / w).rounded())
                          : CGSize(width: (1080 * w / h).rounded(), height: 1080)
        }
        return nil
    }

    /// Zoom is expressed as **the reciprocal of the fraction of source width visible**: 1 = the whole
    /// width (overview), 2 = half the width, and so on.
    ///
    /// `fillZoom` is the zoom at which the target frame is exactly filled while still showing the
    /// source's **full height** — the natural "mobile" framing for a landscape screen: crop the sides,
    /// fill the height. Below it the output is letterboxed; at or above it the frame is full.
    static func fillZoom(source: CGSize, target: CGSize) -> CGFloat {
        guard source.width > 0, source.height > 0, target.height > 0 else { return 1 }
        let aspect = target.width / target.height
        return max(1, source.width / (aspect * source.height))
    }

    /// Where the camera samples, and where that lands in the output.
    struct View {
        /// The sampled rect in source pixels, top-left origin. Guaranteed inside the source.
        var rect: CGRect
        /// Uniform scale from source pixels to output pixels.
        var scale: CGFloat
        /// Offset of the scaled content inside the output frame (letterbox margins).
        var offsetX: CGFloat
        var offsetY: CGFloat
        /// True when the rect wanted to be taller than the source: vertical panning is disabled for
        /// this frame and the remainder is letterboxed.
        var verticalPanDisabled: Bool
    }

    /// The sampling rect for a camera at `zoom` centred on normalized `center` (0…1, top-left
    /// origin), rendering `source` into `target`.
    ///
    /// Clamping is applied *here*, after any interpolation upstream, so no caller can produce a rect
    /// that leaves the source. When the required height exceeds the source, the rect is limited to the
    /// full source height, vertical panning is disabled, and the leftover output height becomes a
    /// letterbox margin.
    static func view(zoom: CGFloat, center: CGPoint, source: CGSize, target: CGSize) -> View {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else {
            return View(rect: CGRect(origin: .zero, size: source), scale: 1,
                        offsetX: 0, offsetY: 0, verticalPanDisabled: true)
        }
        let aspect = target.width / target.height
        var vw = source.width / max(1, zoom)
        var vh = vw / aspect
        var verticalDisabled = false
        if vh >= source.height {                 // taller than the source → letterbox, no vertical pan
            vh = source.height
            verticalDisabled = true
        }
        if vw > source.width {                   // safety: never wider than the source
            vw = source.width
            vh = min(source.height, vw / aspect)
        }
        // Round the size first, then clamp the origin against the rounded size, so independent
        // rounding can never push the rect a pixel past the edge.
        vw = min(vw.rounded(), source.width)
        vh = min(vh.rounded(), source.height)

        var x = (center.x * source.width - vw / 2).rounded()
        x = min(max(x, 0), source.width - vw)
        var y: CGFloat
        if verticalDisabled {
            y = ((source.height - vh) / 2).rounded()   // full height: nothing to pan
        } else {
            y = (center.y * source.height - vh / 2).rounded()
            y = min(max(y, 0), source.height - vh)
        }

        let scale = target.width / vw
        let offsetX = ((target.width - vw * scale) / 2).rounded()
        let offsetY = ((target.height - vh * scale) / 2).rounded()
        return View(rect: CGRect(x: x, y: y, width: vw, height: vh), scale: scale,
                    offsetX: offsetX, offsetY: max(0, offsetY),
                    verticalPanDisabled: verticalDisabled)
    }
}
