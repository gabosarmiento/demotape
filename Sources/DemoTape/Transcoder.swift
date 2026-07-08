import Foundation
import AVFoundation
import AppKit
import CoreImage
import CoreVideo
import Metal
import AudioToolbox

/// Downscales a styled master into a lightweight, web-ready MP4 (H.264 + AAC, faststart)
/// at a chosen height tier with a modest target bitrate. Built for fast-loading inline demos.
final class Transcoder {

    /// Video bitrate (kbps) per height tier. Tuned for small, fast-loading demo clips,
    /// with ~30% headroom so fast zoom/scroll transitions stay clean.
    static let bitrateKbps: [Int: Int] = [360: 910, 480: 1430, 540: 1820, 720: 2860]
    static let tiers = [360, 480, 540, 720]

    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    enum TranscodeError: LocalizedError {
        case noVideoTrack, writerFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The video has no video track."
            case .writerFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    /// Estimated output size in bytes for a duration and tier.
    static func estimatedBytes(duration: Double, height: Int, audioKbps: Int = 96) -> Int {
        let v = bitrateKbps[height] ?? 1400
        return Int(duration * Double(v + audioKbps) * 1000 / 8)
    }

    func transcode(input: URL, to outURL: URL, height: Int, audioKbps: Int = 96) throws {
        let asset = AVAsset(url: input)
        guard let vTrack = asset.tracks(withMediaType: .video).first else { throw TranscodeError.noVideoTrack }

        let src = vTrack.naturalSize
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        var th = CGFloat(height)
        var tw = src.height > 0 ? src.width * (th / src.height) : src.width
        if tw > 1280 { let k = 1280 / tw; tw *= k; th *= k } // cap width
        let outW = even(tw), outH = even(th)
        let vKbps = Self.bitrateKbps[height] ?? 1400

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
                AVVideoAverageBitRateKey: vKbps * 1000,
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

        // Audio → AAC.
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

        guard reader.startReading() else { throw TranscodeError.writerFailed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        // Audio pump (concurrent — avoids the interleave deadlock).
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

        let sx = outW / src.width, sy = outH / src.height
        let queue = DispatchQueue(label: "pro.demotape.transcode")
        let done = DispatchSemaphore(value: 0)
        vIn.requestMediaDataWhenReady(on: queue) { [self] in
            while vIn.isReadyForMoreMediaData {
                if writer.status != .writing { done.signal(); return }
                guard let sample = vOut.copyNextSampleBuffer() else { vIn.markAsFinished(); done.signal(); return }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let scaled = CIImage(cvImageBuffer: pb).transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                guard let pool = adaptor.pixelBufferPool else { continue }
                var outBuf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                guard let outBuf = outBuf else { continue }
                ciContext.render(scaled, to: outBuf, bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
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
        if writer.status != .completed {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        Log.write("Transcoder: \(Int(outW))x\(Int(outH)) @ \(vKbps)kbps -> \(outURL.lastPathComponent)")
    }

    /// Saves a poster JPEG from a representative frame.
    func savePoster(from input: URL, to outURL: URL, maxHeight: Int) {
        let asset = AVAsset(url: input)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 0, height: CGFloat(maxHeight))
        let time = CMTime(seconds: min(1.0, CMTimeGetSeconds(asset.duration) * 0.15), preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? data.write(to: outURL)
        }
    }
}
