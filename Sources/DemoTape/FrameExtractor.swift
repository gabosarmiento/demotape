import AVFoundation
import AppKit

/// Extracts still keyframes from a video at requested timestamps and writes them as PNGs. Used by
/// `AIBriefBuilder` to give the model (and the consuming agent) a handful of screenshots.
///
/// Includes a light **visual de-duplication** pass: a candidate frame is skipped when it's nearly
/// identical to the last kept frame (compared on a tiny downscaled thumbnail), so a mostly-static
/// screen doesn't produce a run of copies.
final class FrameExtractor {

    /// Max output height in px (keeps PNGs — and multimodal token cost — small).
    var maxHeight: CGFloat = 768
    /// 0…1 mean per-channel difference below which two frames are considered duplicates.
    var duplicateThreshold: Double = 0.012

    /// Renders `times` (seconds) from `video` into `dir` as PNGs, returning the frames actually
    /// kept (deduped), each with its `frames/`-relative filename. `dir` must already exist.
    func extract(from video: URL, at times: [Double], into dir: URL) -> [AIBrief.Frame] {
        let asset = AVAsset(url: video)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 0, height: maxHeight)

        var kept: [AIBrief.Frame] = []
        var lastSignature: [Double]? = nil

        for t in times.sorted() {
            let cm = CMTime(seconds: t, preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: cm, actualTime: nil) else { continue }

            let signature = Self.signature(of: cg)
            if let last = lastSignature, Self.meanDifference(last, signature) < duplicateThreshold {
                continue   // near-identical to the previous kept frame — skip
            }

            let filename = AIBrief.frameFilename(forTimestamp: t)
            let outURL = dir.appendingPathComponent(filename)
            guard Self.writePNG(cg, to: outURL) else { continue }
            kept.append(AIBrief.Frame(t: t, filename: filename, note: nil))
            lastSignature = signature
        }
        return kept
    }

    // MARK: - PNG writing

    private static func writePNG(_ cg: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    // MARK: - De-dup signature (tiny grayscale thumbnail)

    /// A coarse fingerprint: mean luminance of an 8×8 grid, in 0…1. Cheap and robust enough to
    /// catch "the screen didn't visibly change" between two candidate timestamps.
    private static func signature(of image: CGImage) -> [Double] {
        let n = 8
        let bytesPerRow = n * 4
        var buffer = [UInt8](repeating: 0, count: n * n * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buffer, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return []
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var out = [Double](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            let r = Double(buffer[i * 4]), g = Double(buffer[i * 4 + 1]), b = Double(buffer[i * 4 + 2])
            out[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }
        return out
    }

    /// Mean absolute difference between two equal-length signatures (0…1). Returns 1 (max) when the
    /// signatures are missing or mismatched, so we never wrongly treat them as duplicates.
    private static func meanDifference(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 1 }
        var sum = 0.0
        for i in 0..<a.count { sum += abs(a[i] - b[i]) }
        return sum / Double(a.count)
    }
}
