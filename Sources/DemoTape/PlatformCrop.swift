import Foundation
import AVFoundation
import CoreImage
import Metal

/// Pure geometry for the platform export: what to crop, and whether a crop is even needed.
enum PlatformFit {

    /// The largest centered rect of `targetAspect` (w/h) that fits entirely inside `source` — a
    /// center crop-to-fill. Used to reshape a capture to a platform ratio without letterboxing.
    static func cropRect(source: CGSize, targetAspect: CGFloat) -> CGRect {
        guard source.width > 0, source.height > 0, targetAspect > 0 else {
            return CGRect(origin: .zero, size: source)
        }
        let srcAspect = source.width / source.height
        var w = source.width, h = source.height
        if srcAspect > targetAspect {
            w = source.height * targetAspect      // too wide → trim the sides
        } else {
            h = source.width / targetAspect       // too tall → trim top and bottom
        }
        return CGRect(x: ((source.width - w) / 2).rounded(),
                      y: ((source.height - h) / 2).rounded(),
                      width: w.rounded(), height: h.rounded())
    }

    /// Whether `source` already has (near enough) the same aspect as `target` — in which case no
    /// crop is needed and the file can be used as-is (e.g. a Select-Area recording framed to it).
    static func aspectsMatch(_ source: CGSize, _ target: CGSize, epsilon: CGFloat = 0.02) -> Bool {
        guard source.height > 0, target.height > 0 else { return false }
        return abs(source.width / source.height - target.width / target.height) < epsilon
    }
}

/// Produces a platform-optimized derivative: center-crops a recording to a target ratio and scales
/// it to the exact target size (e.g. 1080×1920), re-encoding H.264 + AAC. Non-destructive — writes a
/// new file and leaves the original untouched. Modeled on `Transcoder` (same reader/writer shape),
/// but crops-to-fill instead of preserving the source ratio.
final class PlatformCrop {

    enum CropError: LocalizedError {
        case noVideoTrack, writerFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The video has no video track."
            case .writerFailed(let m): return "Export failed: \(m)"
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

    func export(source: URL, to outURL: URL, targetSize: CGSize,
                audioKbps: Int = 128, progress: ((Double) -> Void)? = nil) throws {
        let asset = AVAsset(url: source)
        guard let vTrack = asset.tracks(withMediaType: .video).first else { throw CropError.noVideoTrack }

        // Our recordings are stored upright (identity transform), so crop in pixel space directly.
        let srcSize = vTrack.naturalSize
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        let outW = even(targetSize.width), outH = even(targetSize.height)
        let crop = PlatformFit.cropRect(source: srcSize, targetAspect: outW / outH)
        let duration = CMTimeGetSeconds(asset.duration)

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
            AVVideoWidthKey: Int(outW),
            AVVideoHeightKey: Int(outH),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(for: CGSize(width: outW, height: outH)),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ]
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outW),
                kCVPixelBufferHeightKey as String: Int(outH)
            ])
        writer.add(vIn)

        // Audio → AAC, in a concurrent pump (matches Transcoder to avoid the interleave deadlock).
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
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: audioKbps * 1000
            ])
            ain.expectsMediaDataInRealTime = false
            writer.add(ain)
            aReader = ar; aOut = out; aIn = ain
        }

        guard reader.startReading() else { throw CropError.writerFailed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw CropError.writerFailed(writer.error?.localizedDescription ?? "writer") }
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

        // Crop → move to origin → scale to the exact target.
        let sx = outW / crop.width, sy = outH / crop.height
        let queue = DispatchQueue(label: "pro.demotape.platformcrop")
        let done = DispatchSemaphore(value: 0)
        vIn.requestMediaDataWhenReady(on: queue) { [self] in
            while vIn.isReadyForMoreMediaData {
                if writer.status != .writing { done.signal(); return }
                guard let sample = vOut.copyNextSampleBuffer() else { vIn.markAsFinished(); done.signal(); return }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let img = CIImage(cvImageBuffer: pb)
                    .cropped(to: crop)
                    .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                    .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                guard let pool = adaptor.pixelBufferPool else { continue }
                var outBuf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                guard let outBuf = outBuf else { continue }
                ciContext.render(img, to: outBuf, bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                                 colorSpace: colorSpace)
                adaptor.append(outBuf, withPresentationTime: pts)
                if duration > 0 { progress?(min(1, CMTimeGetSeconds(pts) / duration)) }
            }
        }
        done.wait()
        vIn.markAsFinished()
        audioGroup.wait()

        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        guard writer.status == .completed else {
            throw CropError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        Log.write("PlatformCrop: \(Int(outW))x\(Int(outH)) -> \(outURL.lastPathComponent)")
    }

    private func bitrate(for size: CGSize) -> Int {
        // Scale roughly with area; keep demo clips light. ~1080p portrait ≈ 4 Mbps.
        let mp = (size.width * size.height) / 1_000_000
        return Int(max(1_200_000, min(6_000_000, mp * 2_000_000)))
    }
}
