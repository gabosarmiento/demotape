import Foundation
import AVFoundation
import CoreImage
import CoreText
import CoreVideo
import Metal
import AppKit

/// Burns caption cues into a video, producing a new `…captioned.mp4` (H.264 + AAC, faststart).
/// Full resolution is preserved; text is drawn bottom-center with a rounded translucent box.
/// Text overlays are rendered once per cue (Core Text → CGImage) and composited per frame.
final class CaptionBurner {

    enum BurnError: LocalizedError {
        case noVideoTrack, failed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The video has no video track."
            case .failed(let m): return "Caption burn failed: \(m)"
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

    func burn(video: URL, cues: [CaptionCue], to outURL: URL) throws {
        let asset = AVAsset(url: video)
        guard let vTrack = asset.tracks(withMediaType: .video).first else { throw BurnError.noVideoTrack }
        let size = vTrack.naturalSize
        let sorted = cues.sorted { $0.start < $1.start }

        // Pre-render one overlay image per cue (bottom-center, boxed).
        var overlays: [Int: CIImage] = [:]
        for (i, cue) in sorted.enumerated() {
            if let img = makeOverlay(text: cue.text, videoSize: size) { overlays[i] = img }
        }

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)

        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * 4),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ]
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
        writer.add(vIn)

        // Audio → AAC (concurrent pump, mirrors Transcoder).
        var aReader: AVAssetReader?
        var aOut: AVAssetReaderTrackOutput?
        var aIn: AVAssetWriterInput?
        if let aTrack = asset.tracks(withMediaType: .audio).first {
            let ar = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            ar.add(out)
            let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000
            ])
            ain.expectsMediaDataInRealTime = false
            writer.add(ain)
            aReader = ar; aOut = out; aIn = ain
        }

        guard reader.startReading() else { throw BurnError.failed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw BurnError.failed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let audioGroup = DispatchGroup()
        if let ar = aReader, let out = aOut, let ain = aIn {
            ar.startReading()
            audioGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while ar.status == .reading {
                    if writer.status != .writing { break }
                    guard let sb = out.copyNextSampleBuffer() else { break }
                    while !ain.isReadyForMoreMediaData { if writer.status != .writing { break }; usleep(1000) }
                    if writer.status != .writing { break }
                    ain.append(sb)
                }
                ain.markAsFinished()
                audioGroup.leave()
            }
        }

        let queue = DispatchQueue(label: "pro.demotape.caption-burn")
        let done = DispatchSemaphore(value: 0)
        vIn.requestMediaDataWhenReady(on: queue) { [self] in
            while vIn.isReadyForMoreMediaData {
                if writer.status != .writing { done.signal(); return }
                guard let sample = vOut.copyNextSampleBuffer() else { vIn.markAsFinished(); done.signal(); return }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let t = CMTimeGetSeconds(pts)
                var image = CIImage(cvImageBuffer: pb)

                if let idx = activeCueIndex(at: t, in: sorted), let overlay = overlays[idx] {
                    // Bottom-center, with a margin proportional to height.
                    let margin = size.height * 0.06
                    let x = (size.width - overlay.extent.width) / 2
                    let placed = overlay.transformed(by: CGAffineTransform(translationX: x, y: margin))
                    image = placed.composited(over: image)
                }

                guard let pool = adaptor.pixelBufferPool else { continue }
                var outBuf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                guard let outBuf = outBuf else { continue }
                ciContext.render(image, to: outBuf,
                                 bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                                 colorSpace: colorSpace)
                adaptor.append(outBuf, withPresentationTime: pts)
            }
        }
        done.wait()
        vIn.markAsFinished()
        audioGroup.wait()

        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        guard writer.status == .completed else {
            throw BurnError.failed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        Log.write("CaptionBurner: \(sorted.count) cues -> \(outURL.lastPathComponent)")
    }

    private func activeCueIndex(at t: Double, in cues: [CaptionCue]) -> Int? {
        for (i, c) in cues.enumerated() where t >= c.start && t < c.end { return i }
        return nil
    }

    /// Renders a caption string into a bottom-bar overlay image (rounded translucent box +
    /// centered white text), wrapped to ~86% of the video width. Core Text only — no AppKit
    /// drawing context, so it's safe off the main thread.
    private func makeOverlay(text: String, videoSize: CGSize) -> CIImage? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        let fontSize = max(18, videoSize.height * 0.045)
        let maxTextWidth = videoSize.width * 0.86
        let padX: CGFloat = fontSize * 0.7
        let padY: CGFloat = fontSize * 0.45

        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.cgColor,
            .paragraphStyle: para
        ]
        let attr = NSAttributedString(string: clean, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let constraint = CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: attr.length), nil, constraint, nil)

        let boxW = ceil(textSize.width) + padX * 2
        let boxH = ceil(textSize.height) + padY * 2
        guard boxW > 0, boxH > 0 else { return nil }

        guard let ctx = CGContext(data: nil, width: Int(boxW), height: Int(boxH),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Rounded translucent background.
        let box = CGRect(x: 0, y: 0, width: boxW, height: boxH)
        let radius = min(boxH * 0.28, 22)
        let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath()

        // Text frame, vertically padded.
        let textRect = CGRect(x: padX, y: padY, width: ceil(textSize.width), height: ceil(textSize.height))
        let frame = CTFramesetterCreateFrame(framesetter,
            CFRange(location: 0, length: attr.length),
            CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
