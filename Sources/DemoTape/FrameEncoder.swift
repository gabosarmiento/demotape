import Foundation
import AVFoundation
import CoreImage
import ImageIO
import Metal

/// Encodes a captured still-frame sequence into an H.264 `.mov` that the rest of DemoTape treats as an
/// ordinary raw recording — so the styled render, auto-zoom, captions, voiceover and reframe all work
/// on footage that was never captured by the screen recorder.
///
/// This is what lets an agent produce a finished demo on a Mac that has never granted Screen
/// Recording: the browser is captured over the DevTools protocol as JPEGs, the driver writes the
/// matching `events.json` from the actions it performed, and `--render` takes it from there.
///
/// Apple frameworks only (AVFoundation + ImageIO + Core Image), consistent with the project's
/// no-dependency constraint. Notably this does *not* go through a WebM/VP8 path: Playwright's own video
/// format can't be decoded by AVFoundation, which is precisely why frames are the interchange.
final class FrameEncoder {

    enum EncodeError: LocalizedError {
        case noFrames
        case unreadableFrame(String)
        case writerFailed(String)
        var errorDescription: String? {
            switch self {
            case .noFrames: return "The frame manifest lists no usable frames."
            case .unreadableFrame(let p): return "Couldn't read frame: \(p)"
            case .writerFailed(let m): return "Encoding failed: \(m)"
            }
        }
    }

    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// Encode `sequence` (resolved against `directory`) into `outURL`.
    /// Returns the encoded size and duration so the caller can write a matching events sidecar.
    @discardableResult
    func encode(sequence: FrameSequence, directory: URL, to outURL: URL,
                progress: ((Double) -> Void)? = nil) throws -> (size: CGSize, duration: Double) {
        // Lay the capture out at a constant rate, holding each image until the next arrives — a
        // screencast only paints on change, and the renderer can't invent the frames in between.
        let frames = sequence.heldTimeline(relativeTo: directory, rate: sequence.fps ?? 30)
        guard !frames.isEmpty else { throw EncodeError.noFrames }

        // Output size: the manifest's, else the first frame's. Even dimensions for H.264/yuv420p.
        let firstImage = try loadImage(frames[0].url)
        let natural = CGSize(width: CGFloat(firstImage.width), height: CGFloat(firstImage.height))
        let target = sequence.declaredSize ?? natural
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }
        let outW = even(target.width), outH = even(target.height)
        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outW), AVVideoHeightKey: Int(outH),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(for: CGSize(width: outW, height: outH)),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true,
            ]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outW),
                kCVPixelBufferHeightKey as String: Int(outH),
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw EncodeError.writerFailed(writer.error?.localizedDescription ?? "writer")
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let total = Double(frames.count)
        var encoded = 0
        var lastURL: URL?
        var lastImage: CGImage?

        for (i, frame) in frames.enumerated() {
            // Backpressure: the writer pulls, so wait rather than buffering the whole capture.
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { break }
                usleep(2000)
            }
            if writer.status != .writing { break }

            // A held timeline repeats the same file many times over, so decoding once and reusing it
            // is the difference between a few seconds and a minute of work.
            let image: CGImage
            if frame.url == lastURL, let cached = lastImage {
                image = cached
            } else {
                // A dropped/corrupt frame shouldn't abandon the whole take — skip this timestamp, and
                // only fail if nothing at all could be encoded.
                guard let decoded = try? loadImage(frame.url) else { continue }
                image = decoded
                lastURL = frame.url
                lastImage = decoded
            }
            guard let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer = buffer else { continue }

            var ci = CIImage(cgImage: image)
            // Scale to the output box if the capture changed size mid-run (a window resize does this).
            if ci.extent.width != outW || ci.extent.height != outH {
                let s = min(outW / ci.extent.width, outH / ci.extent.height)
                let scaled = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
                let dx = ((outW - scaled.extent.width) / 2).rounded()
                let dy = ((outH - scaled.extent.height) / 2).rounded()
                ci = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
                    .composited(over: CIImage(color: .black).cropped(to: outRect))
            }
            ciContext.render(ci.cropped(to: outRect), to: buffer, bounds: outRect, colorSpace: colorSpace)
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: frame.t, preferredTimescale: timescale))
            encoded += 1
            if i % 10 == 0 { progress?(Double(i) / total) }
        }

        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        guard writer.status == .completed else {
            throw EncodeError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        guard encoded > 0 else { throw EncodeError.noFrames }
        progress?(1)

        let duration = frames.last?.t ?? 0
        Log.write("FrameEncoder: \(encoded)/\(frames.count) frames -> \(Int(outW))x\(Int(outH)) \(outURL.lastPathComponent)")
        return (CGSize(width: outW, height: outH), duration)
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw EncodeError.unreadableFrame(url.lastPathComponent)
        }
        return image
    }

    private func bitrate(for size: CGSize) -> Int {
        let mp = (size.width * size.height) / 1_000_000
        return Int(max(2_000_000, min(12_000_000, mp * 4_000_000)))
    }
}
