import Foundation
import CoreImage
import AppKit

/// Normalizes a user photo before sending it to the avatar provider. Selfies are usually framed
/// tight (little headroom), which makes the generated avatar crop badly in a circular PiP. We
/// pad the photo with headroom on a solid backdrop sampled from the top of the image, so the
/// provider renders a well-framed, "not too close" presenter that fills a circle cleanly.
enum AvatarImagePrep {

    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    /// Returns a temporary PNG with added headroom/margins. Falls back to the original URL if
    /// anything goes wrong (never blocks generation).
    static func paddedForHeadroom(_ imageURL: URL) -> URL {
        guard let ci = load(imageURL) else { return imageURL }
        let e = ci.extent
        guard e.width > 0, e.height > 0 else { return imageURL }

        // Margins: generous headroom on top, modest sides/bottom.
        let topPad = e.height * 0.55
        let bottomPad = e.height * 0.12
        let sidePad = e.width * 0.22
        let canvasW = e.width + sidePad * 2
        let canvasH = e.height + topPad + bottomPad

        let bg = CIImage(color: sampleTopColor(ci)).cropped(to: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        // Place the source near the bottom-center so the padding above becomes headroom.
        let placed = ci
            .transformed(by: CGAffineTransform(translationX: sidePad - e.minX, y: bottomPad - e.minY))
        let composed = placed.composited(over: bg).cropped(to: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        guard let cg = ctx.createCGImage(composed, from: composed.extent) else { return imageURL }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-avatar-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return imageURL }
        do { try data.write(to: out); return out } catch { return imageURL }
    }

    private static func load(_ url: URL) -> CIImage? {
        if let ci = CIImage(contentsOf: url) { return ci }
        guard let ns = NSImage(contentsOf: url), let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Average color of a thin strip across the top of the image (usually the wall behind).
    private static func sampleTopColor(_ image: CIImage) -> CIColor {
        let e = image.extent
        let strip = CGRect(x: e.minX, y: e.maxY - e.height * 0.06, width: e.width, height: e.height * 0.06)
        let avg = image.applyingFilter("CIAreaAverage",
                                       parameters: [kCIInputExtentKey: CIVector(cgRect: strip)])
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return CIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255)
    }
}
