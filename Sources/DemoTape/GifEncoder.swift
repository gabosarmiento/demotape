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

        // Inter-frame differencing: ImageIO GIFs don't delta-compress, so a mostly-static screen
        // recording balloons. We render each frame to RGBA, and for every frame after the first we
        // set pixels that barely changed from the previous frame to fully transparent. GIF stores
        // those as a single transparent palette index (long LZW runs → tiny), and the decoder shows
        // the prior frame underneath. This is the standard GIF-optimizer trick, done with no deps.
        let w = Int(outW), h = Int(outH)
        let bpr = w * 4
        let byteCount = bpr * h
        let curBuf = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        let prevBuf = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        defer { curBuf.deallocate(); prevBuf.deallocate() }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawCtx = CGContext(data: curBuf, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: bpr, space: colorSpace, bitmapInfo: bitmapInfo)
        // Pixels whose R+G+B differ from the previous frame by <= this are treated as unchanged.
        let threshold = 12
        var hasPrev = false

        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts > maxDuration { CMSampleBufferInvalidate(sample); break }
            guard pts - lastEmitted >= interval - 0.001 else { CMSampleBufferInvalidate(sample); continue }
            lastEmitted = pts
            guard let pb = CMSampleBufferGetImageBuffer(sample), let ctx = drawCtx else {
                CMSampleBufferInvalidate(sample); continue
            }
            let scaled = CIImage(cvImageBuffer: pb).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = ciContext.createCGImage(scaled, from: bounds, format: .RGBA8, colorSpace: colorSpace) else {
                CMSampleBufferInvalidate(sample); continue
            }
            ctx.clear(bounds)
            ctx.draw(cg, in: bounds)

            let cur = curBuf.assumingMemoryBound(to: UInt8.self)
            if hasPrev {
                let prev = prevBuf.assumingMemoryBound(to: UInt8.self)
                var i = 0
                while i < byteCount {
                    let d = abs(Int(cur[i]) - Int(prev[i]))
                          + abs(Int(cur[i + 1]) - Int(prev[i + 1]))
                          + abs(Int(cur[i + 2]) - Int(prev[i + 2]))
                    cur[i + 3] = d <= threshold ? 0 : 255   // unchanged → transparent
                    i += 4
                }
            } else {
                var i = 3
                while i < byteCount { cur[i] = 255; i += 4 }   // first frame fully opaque
            }

            // Build a straight-alpha CGImage from a snapshot of the buffer (so the next frame can
            // overwrite curBuf) and hand it to the GIF writer.
            let snapshot = Data(bytes: curBuf, count: byteCount)
            if let provider = CGDataProvider(data: snapshot as CFData),
               let outImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: bpr, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                CGImageDestinationAddImage(dest, outImage, frameProps)
                frames += 1
            }
            memcpy(prevBuf, curBuf, byteCount)   // compare against the last full frame next time
            hasPrev = true
            CMSampleBufferInvalidate(sample)
        }

        guard frames > 0, CGImageDestinationFinalize(dest) else { throw GifError.finalizeFailed }
        Log.write("GifEncoder: \(Int(outW))x\(Int(outH)) @ \(fps)fps, \(frames) frames (diffed) -> \(outURL.lastPathComponent)")
    }
}
