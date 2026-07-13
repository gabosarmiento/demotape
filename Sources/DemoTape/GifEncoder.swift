import Foundation
import AVFoundation
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Encodes a video into an animated GIF using ImageIO (no third-party dependencies).
/// Samples the source at a target frame rate, scales to a target width, and writes a
/// looping GIF. GIFs are palette-limited (256 colors) — great for short, silent demo loops
/// to drop into a README.
final class GifEncoder {

    enum GifError: LocalizedError {
        case noVideoTrack, readerFailed(String), destinationFailed, finalizeFailed
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The video has no video track."
            case .readerFailed(let m): return "Couldn't read the video: \(m)"
            case .destinationFailed: return "Couldn't create the GIF file."
            case .finalizeFailed: return "Couldn't finalize the GIF."
            }
        }
    }

    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    /// Writes `video` to `outURL` as a looping GIF. `maxWidth` caps the width (aspect kept),
    /// `fps` is the GIF frame rate, `maxDuration` caps length (GIFs balloon quickly).
    func encode(video: URL, to outURL: URL, maxWidth: Int, fps: Double, maxDuration: Double = 30) throws {
        let asset = AVAsset(url: video)
        guard let track = asset.tracks(withMediaType: .video).first else { throw GifError.noVideoTrack }

        let src = track.naturalSize
        let scale = min(1, CGFloat(maxWidth) / max(1, src.width))
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        let outW = even(src.width * scale), outH = even(src.height * scale)
        let duration = min(CMTimeGetSeconds(asset.duration), maxDuration)
        let estCount = max(1, Int(duration * fps) + 1)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GifError.readerFailed("cannot add output") }
        reader.add(output)
        guard reader.startReading() else { throw GifError.readerFailed(reader.error?.localizedDescription ?? "unknown") }

        try? FileManager.default.removeItem(at: outURL)
        let type = UTType.gif.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, type, estCount, nil) else {
            throw GifError.destinationFailed
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]   // loop forever
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1.0 / fps,
                kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps
            ]
        ] as CFDictionary

        let interval = 1.0 / fps
        var lastEmitted = -Double.greatestFiniteMagnitude
        var frames = 0
        let bounds = CGRect(x: 0, y: 0, width: outW, height: outH)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts > maxDuration { CMSampleBufferInvalidate(sample); break }
            guard pts - lastEmitted >= interval - 0.001 else { CMSampleBufferInvalidate(sample); continue }
            lastEmitted = pts
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let scaled = CIImage(cvImageBuffer: pb).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = ciContext.createCGImage(scaled, from: bounds, format: .RGBA8, colorSpace: colorSpace) {
                CGImageDestinationAddImage(dest, cg, frameProps)
                frames += 1
            }
            CMSampleBufferInvalidate(sample)
        }

        guard frames > 0, CGImageDestinationFinalize(dest) else { throw GifError.finalizeFailed }
        Log.write("GifEncoder: \(Int(outW))x\(Int(outH)) @ \(fps)fps, \(frames) frames -> \(outURL.lastPathComponent)")
    }
}
