import Foundation
import AVFoundation
import AppKit
import CoreImage
import CoreGraphics
import CoreVideo
import Metal
import AudioToolbox

/// Turns a raw screen recording + its event timeline into a styled video:
/// spring-smoothed auto-zoom on clicks/typing, a synthetic smooth cursor, and
/// keyboard-shortcut badges. Optional gradient background/padding for window/region
/// captures (off for full-screen). Fully offline; no permissions.
final class VideoRenderer {

    struct Style {
        /// Framing (background + padding) — only makes sense for window/region capture.
        var useBackground = false
        var padding: CGFloat = 48
        var cornerRadius: CGFloat = 20
        var bgTop = CIColor(red: 0.16, green: 0.18, blue: 0.30)
        var bgBottom = CIColor(red: 0.06, green: 0.07, blue: 0.12)
        /// Optional background image (e.g. the desktop wallpaper), blurred behind the content.
        var backgroundImageURL: URL?

        var maxZoom: CGFloat = 2.0
        // Spring camera (critically damped ≈ 2·√stiffness).
        var stiffness: CGFloat = 130
        var damping: CGFloat = 23

        var drawCursor = true
        var cursorScale: CGFloat = 1.7
        var cursorSmoothing: CGFloat = 0.7   // EMA for cursor position (higher = less lag)

        var showShortcuts = true
        var showClickRipples = true
        var clickRippleDuration: Double = 0.5
        /// Output frame rate (web standard is 30).
        var outputFPS: Double = 30
        /// Linear gain applied to the mic audio (built-in mics record quietly).
        var volumeGain: Float = 3.0

        // Webcam picture-in-picture
        var webcamDiameterFraction: CGFloat = 0.22
        var webcamMirror = true
        /// Circle center, normalized to the output (top-left origin).
        var webcamCenterX: CGFloat = 0.14
        var webcamCenterY: CGFloat = 0.82
        /// Zoom into the camera image (1 = full frame).
        var webcamZoom: CGFloat = 1.0
    }

    // Cached webcam overlay layers (per render).
    private var wcMask: CIImage?
    private var wcRing: CIImage?

    enum RenderError: LocalizedError {
        case noVideoTrack, readerFailed(String), writerFailed(String), noPixelBufferPool
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video track."
            case .readerFailed(let m): return "Reader failed: \(m)"
            case .writerFailed(let m): return "Writer failed: \(m)"
            case .noPixelBufferPool: return "Could not allocate a pixel buffer pool."
            }
        }
    }

    // GPU-backed context (Metal) is dramatically faster than the default on Intel.
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func render(videoURL: URL, metadata: RecordingMetadata, cameraURL: URL? = nil,
                to outURL: URL, style: Style = Style()) throws {
        let asset = AVAsset(url: videoURL)
        guard let track = asset.tracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }

        let srcSize = track.naturalSize
        let W = srcSize.width, H = srcSize.height
        let pad = style.useBackground ? style.padding : 0
        // H.264 / yuv420p require even dimensions for web playback.
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        let outW = even(W + pad * 2)
        let outH = even(H + pad * 2)
        let contentW = outW - pad * 2
        let contentH = outH - pad * 2
        let frameInterval = 1.0 / style.outputFPS

        // Reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw RenderError.readerFailed("cannot add output") }
        reader.add(readerOutput)

        // Writer
        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true // faststart: moov atom at front for the web
        let keyframeInterval = Int((style.outputFPS * 2).rounded())
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outW),
            AVVideoHeightKey: Int(outH),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(outW * outH) * 8,
                AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outW),
                kCVPixelBufferHeightKey as String: Int(outH)
            ])
        guard writer.canAdd(writerInput) else { throw RenderError.writerFailed("cannot add input") }
        writer.add(writerInput)

        // Audio source: prefer the camera file if it carries the mic (webcam mode →
        // audio shares the webcam clock). Otherwise use the screen file's audio.
        var audioAsset = asset
        var audioOffset = 0.0
        if let cameraURL = cameraURL {
            let camAsset = AVAsset(url: cameraURL)
            if camAsset.tracks(withMediaType: .audio).first != nil {
                audioAsset = camAsset
                audioOffset = metadata.cameraStartOffset ?? 0
            }
        }

        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        var audioGain: Float = style.volumeGain
        if let audioTrack = audioAsset.tracks(withMediaType: .audio).first {
            audioGain = normalizedGain(track: audioTrack, in: audioAsset)
            Log.write("VideoRenderer: audioGain=\(audioGain)")
            let ar = try AVAssetReader(asset: audioAsset)
            // Decode to canonical stereo 48k PCM, then encode AAC for a web-standard MP4.
            let aout = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            aout.alwaysCopiesSampleData = true // we modify PCM in place for gain
            if ar.canAdd(aout) { ar.add(aout) }
            let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ])
            ain.expectsMediaDataInRealTime = false
            if writer.canAdd(ain) { writer.add(ain) }
            audioReader = ar; audioOutput = aout; audioInput = ain
        }

        // Static layers (only for framed mode)
        let background = style.useBackground ? makeBackground(size: CGSize(width: outW, height: outH), style: style) : nil
        let mask = style.useBackground ? makeRoundedMask(width: contentW, height: contentH, radius: style.cornerRadius) : nil
        let shadow = style.useBackground ? makeShadow(contentW: contentW, contentH: contentH, outW: outW, outH: outH, padding: pad, radius: style.cornerRadius) : nil
        let cursorImage = style.drawCursor ? makeCursorImage(scale: style.cursorScale) : nil
        let rippleRing = style.showClickRipples ? makeRing(diameter: 220) : nil
        let rippleBase: CGFloat = 220

        guard reader.startReading() else { throw RenderError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        guard writer.startWriting() else { throw RenderError.writerFailed(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)

        // Webcam source (optional) — read forward, keeping the frame nearest each screen time.
        var camOutput: AVAssetReaderTrackOutput?
        var camPending: CMSampleBuffer?
        var lastCam: CIImage?
        if let cameraURL = cameraURL {
            let camAsset = AVAsset(url: cameraURL)
            if let camTrack = camAsset.tracks(withMediaType: .video).first {
                let cr = try AVAssetReader(asset: camAsset)
                let co = AVAssetReaderTrackOutput(
                    track: camTrack,
                    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                co.alwaysCopiesSampleData = false
                if cr.canAdd(co) { cr.add(co) }
                if cr.startReading() { camOutput = co }
            }
        }

        let focus = FocusTimeline(metadata: metadata, maxZoom: style.maxZoom)
        let camera = SpringCamera()
        var lastEmit: Double = -1
        var curEMA: (x: CGFloat, y: CGFloat)? = nil
        var badgeCacheLabel: String? = nil
        var badgeCacheImage: CIImage? = nil
        var frameCount = 0

        // Feed audio concurrently with video. AVAssetWriter interleaves the two tracks,
        // so feeding all of one before the other deadlocks (video input never becomes
        // ready while it waits for audio to catch up).
        let audioGroup = DispatchGroup()
        if let ar = audioReader, let aout = audioOutput, let ain = audioInput {
            ar.startReading()
            audioGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while ar.status == .reading {
                    if writer.status != .writing { break }
                    guard let sb = aout.copyNextSampleBuffer() else { break }
                    let processed = self.processAudio(sb, gain: audioGain, offset: audioOffset) ?? sb
                    while !ain.isReadyForMoreMediaData {
                        if writer.status != .writing { break }
                        usleep(1000)
                    }
                    if writer.status != .writing { break }
                    ain.append(processed)
                }
                ain.markAsFinished()
                audioGroup.leave()
            }
        }

        let videoQueue = DispatchQueue(label: "pro.demotape.render.video")
        let videoDone = DispatchSemaphore(value: 0)
        var renderError: Error?
        // Pipelined encoding: the writer pulls frames as fast as the encoder allows,
        // overlapping decode / GPU-composite / encode instead of busy-waiting.
        writerInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
          while writerInput.isReadyForMoreMediaData {
            if writer.status != .writing { videoDone.signal(); return }
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                writerInput.markAsFinished(); videoDone.signal(); return
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let t = pts.seconds
            // Cap output to the target fps (skip extra source frames).
            if lastEmit >= 0, (t - lastEmit) < frameInterval - 0.001 { continue }
            var dt = lastEmit < 0 ? frameInterval : (t - lastEmit)
            dt = min(max(dt, 1.0 / 240.0), 1.0 / 20.0)
            lastEmit = t

            // Event timeline aligned to the video's first frame (fixes cursor lag).
            let eventT = t + (metadata.eventTimeOffset ?? 0)

            // Spring-smoothed camera (focus normalized to the content region).
            let target = focus.target(at: eventT)
            camera.step(to: target, dt: dt, stiffness: style.stiffness, damping: style.damping)
            let scale = camera.scale, camX = camera.cx, camY = camera.cy

            // 1) Build the framed composition at zoom = 1 (background + rounded content).
            var content = CIImage(cvImageBuffer: pixelBuffer)
                .transformed(by: CGAffineTransform(scaleX: contentW / W, y: contentH / H))
            if style.useBackground, let mask = mask {
                content = content.applyingFilter("CISourceInCompositing",
                                                 parameters: [kCIInputBackgroundImageKey: mask])
            }
            var base = content.transformed(by: CGAffineTransform(translationX: pad, y: pad))
            if let shadow = shadow { base = base.composited(over: shadow) }
            if let background = background { base = base.composited(over: background) }
            base = base.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))

            // 2) Zoom the WHOLE composition toward the focus point (content + frame + bg move together).
            let fx = pad + camX * contentW              // focus in composed coords (top-left)
            let fyTop = pad + camY * contentH
            let vw = outW / scale, vh = outH / scale
            var ox = fx - vw / 2
            var oyBL = (outH - fyTop) - vh / 2
            ox = min(max(ox, 0), outW - vw)
            oyBL = min(max(oyBL, 0), outH - vh)
            var composite = base
                .cropped(to: CGRect(x: ox, y: oyBL, width: vw, height: vh))
                .transformed(by: CGAffineTransform(translationX: -ox, y: -oyBL))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            // Map a region-normalized point to output coords after the zoom (bottom-left).
            func mapToOutput(_ u: CGFloat, _ v: CGFloat) -> CGPoint? {
                let cx = pad + u * contentW
                let cyBL = outH - (pad + v * contentH)
                let px = (cx - ox) * scale
                let py = (cyBL - oyBL) * scale
                if px < 0 || px > outW || py < 0 || py > outH { return nil }
                return CGPoint(x: px, y: py)
            }

            // 3) Overlays, drawn on top of the zoomed composition at constant size.
            if let cursorImage = cursorImage {
                let raw = focus.cursorPoint(at: eventT)
                if curEMA == nil { curEMA = raw }
                curEMA!.x += (raw.x - curEMA!.x) * style.cursorSmoothing
                curEMA!.y += (raw.y - curEMA!.y) * style.cursorSmoothing
                if let p = mapToOutput(curEMA!.x, curEMA!.y) {
                    let h = cursorImage.extent.height
                    composite = cursorImage
                        .transformed(by: CGAffineTransform(translationX: p.x, y: p.y - h))
                        .composited(over: composite)
                }
            }

            if let rippleRing = rippleRing {
                let maxRadius = outW * 0.05
                for c in metadata.clicks {
                    let age = eventT - c.t
                    if age < 0 || age > style.clickRippleDuration { continue }
                    guard let p = mapToOutput(CGFloat(c.x), CGFloat(c.y)) else { continue }
                    let prog = CGFloat(age / style.clickRippleDuration)
                    let radius = maxRadius * prog
                    guard radius > 1 else { continue }
                    let s = (2 * radius) / rippleBase
                    let ring = rippleRing
                        .transformed(by: CGAffineTransform(scaleX: s, y: s))
                        .transformed(by: CGAffineTransform(translationX: p.x - radius, y: p.y - radius))
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - prog)
                        ])
                    composite = ring.composited(over: composite)
                }
            }

            // Webcam PiP — fixed position/size (does not zoom).
            if let camOutput = camOutput {
                let camTarget = t - (metadata.cameraStartOffset ?? 0)
                while true {
                    if let pending = camPending {
                        if CMSampleBufferGetPresentationTimeStamp(pending).seconds <= camTarget {
                            if let pb = CMSampleBufferGetImageBuffer(pending) { lastCam = CIImage(cvImageBuffer: pb) }
                            camPending = nil
                        } else { break }
                    } else if let sb = camOutput.copyNextSampleBuffer() {
                        if CMSampleBufferGetPresentationTimeStamp(sb).seconds <= camTarget {
                            if let pb = CMSampleBufferGetImageBuffer(sb) { lastCam = CIImage(cvImageBuffer: pb) }
                        } else { camPending = sb }
                    } else { break }
                }
                if let cam = lastCam {
                    composite = compositeWebcam(cam, over: composite, outW: outW, outH: outH, style: style)
                }
            }

            // Keyboard-shortcut badge — fixed at bottom center.
            if style.showShortcuts, let label = focus.shortcutBadge(at: eventT) {
                if label != badgeCacheLabel {
                    badgeCacheLabel = label
                    badgeCacheImage = makeBadge(label)
                }
                if let badge = badgeCacheImage {
                    let bx = (outW - badge.extent.width) / 2
                    composite = badge.transformed(by: CGAffineTransform(translationX: bx, y: 90)).composited(over: composite)
                }
            }

            composite = composite.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))

            guard let pool = adaptor.pixelBufferPool else {
                renderError = RenderError.noPixelBufferPool
                writerInput.markAsFinished(); videoDone.signal(); return
            }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer = outBuffer else { continue }
            ciContext.render(composite, to: outBuffer,
                             bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                             colorSpace: colorSpace)

            adaptor.append(outBuffer, withPresentationTime: pts)
            frameCount += 1
          } // while writerInput.isReadyForMoreMediaData
        } // requestMediaDataWhenReady

        videoDone.wait()
        if let renderError = renderError { throw renderError }
        if reader.status == .failed {
            throw RenderError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        audioGroup.wait() // let the concurrent audio pump finish

        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()

        Log.write("VideoRenderer: rendered \(frameCount) frames -> \(outURL.lastPathComponent) status=\(writer.status.rawValue)")
        if writer.status != .completed {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    // MARK: - Audio processing

    /// Analyzes the audio track (peak + RMS) and returns a gain that raises it toward
    /// a broadcast-like loudness without clipping. Built-in mics record very quietly,
    /// so this adapts per-recording instead of using a fixed multiplier.
    private func normalizedGain(track: AVAssetTrack, in asset: AVAsset) -> Float {
        guard let reader = try? AVAssetReader(asset: asset) else { return 4.0 }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return 4.0 }
        reader.add(out)
        guard reader.startReading() else { return 4.0 }

        var peak: Float = 0
        var sumSquares: Double = 0
        var sampleCount: Double = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var total = 0
            var ptr: UnsafeMutablePointer<CChar>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: &total, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
               let ptr = ptr {
                let count = total / MemoryLayout<Int16>.size
                ptr.withMemoryRebound(to: Int16.self, capacity: count) { s in
                    for i in 0..<count {
                        let v = abs(Float(s[i])) / 32767.0
                        if v > peak { peak = v }
                        sumSquares += Double(v) * Double(v)
                        sampleCount += 1
                    }
                }
            }
        }
        guard peak > 0.0005, sampleCount > 0 else { return 1.0 } // silence
        let rms = Float(sqrt(sumSquares / sampleCount))

        // Target a loud RMS (~-16 dBFS) but never let peaks clip, and cap the boost.
        let targetRMS: Float = 0.16
        let rmsGain = rms > 0 ? targetRMS / rms : 30
        let peakGuard = 0.97 / peak
        return min(max(min(rmsGain, peakGuard), 1.0), 30.0)
    }

    /// Applies linear gain to 16-bit PCM in place (louder mic) and shifts the buffer's
    /// presentation time by `offset` seconds (to align camera-clock audio to output).
    private func processAudio(_ sb: CMSampleBuffer, gain: Float, offset: Double) -> CMSampleBuffer? {
        if gain != 1.0, let block = CMSampleBufferGetDataBuffer(sb) {
            var totalLength = 0
            var dataPtr: UnsafeMutablePointer<CChar>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: &totalLength, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
               let dataPtr = dataPtr {
                let count = totalLength / MemoryLayout<Int16>.size
                dataPtr.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                    for i in 0..<count {
                        let scaled = Float(samples[i]) * gain
                        samples[i] = Int16(max(-32768, min(32767, scaled)))
                    }
                }
            }
        }

        guard offset != 0 else { return sb }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing) == noErr else { return sb }
        timing.presentationTimeStamp = timing.presentationTimeStamp + CMTime(seconds: offset, preferredTimescale: 48000)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                              sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                              sampleBufferOut: &out)
        return out ?? sb
    }

    // MARK: - Static layers

    /// Background layer: the desktop wallpaper (scaled-to-fill, blurred, slightly darkened)
    /// when available, otherwise a gradient.
    private func makeBackground(size: CGSize, style: Style) -> CIImage {
        if let url = style.backgroundImageURL, let img = CIImage(contentsOf: url) {
            let ext = img.extent
            if ext.width > 0, ext.height > 0 {
                let scale = max(size.width / ext.width, size.height / ext.height)
                let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let dx = scaled.extent.minX + (scaled.extent.width - size.width) / 2
                let dy = scaled.extent.minY + (scaled.extent.height - size.height) / 2
                let centered = scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
                // Designed gradient backgrounds look best sharp (scaled to fill).
                return centered.clampedToExtent().cropped(to: CGRect(origin: .zero, size: size))
            }
        }
        return makeGradient(size: size, style: style)
    }

    /// A white stroked ring on a clear background (for click ripples).
    private func makeRing(diameter: CGFloat) -> CIImage {
        let d = Int(diameter)
        let ctx = CGContext(data: nil, width: d, height: d, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: d, height: d))
        let lw = diameter * 0.05
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.setLineWidth(lw)
        ctx.strokeEllipse(in: CGRect(x: lw, y: lw, width: diameter - 2 * lw, height: diameter - 2 * lw))
        return CIImage(cgImage: ctx.makeImage()!)
    }

    private func makeGradient(size: CGSize, style: Style) -> CIImage {
        let filter = CIFilter(name: "CILinearGradient")!
        filter.setValue(CIVector(x: 0, y: size.height), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint1")
        filter.setValue(style.bgTop, forKey: "inputColor0")
        filter.setValue(style.bgBottom, forKey: "inputColor1")
        let img = filter.outputImage ?? CIImage(color: style.bgBottom)
        return img.cropped(to: CGRect(origin: .zero, size: size))
    }

    private func makeRoundedMask(width: CGFloat, height: CGFloat, radius: CGFloat) -> CIImage {
        CIImage(cgImage: drawRoundedRect(width: width, height: height, radius: radius,
                                         color: CGColor(red: 1, green: 1, blue: 1, alpha: 1)))
    }

    private func makeShadow(contentW: CGFloat, contentH: CGFloat, outW: CGFloat, outH: CGFloat,
                            padding: CGFloat, radius: CGFloat) -> CIImage {
        let cg = drawRoundedRect(width: contentW, height: contentH, radius: radius,
                                 color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        let shape = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: padding, y: padding - 8))
        return shape.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
            .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
    }

    private func drawRoundedRect(width: CGFloat, height: CGFloat, radius: CGFloat, color: CGColor) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
        return ctx.makeImage()!
    }

    /// A clean, enlarged arrow cursor drawn with CoreGraphics (tip at the image's top-left).
    private func makeCursorImage(scale: CGFloat) -> CIImage {
        let s: CGFloat = 22 * scale
        let w = Int(ceil(s * 0.7)), h = Int(ceil(s))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // Draw in top-left coordinates (flip vertically).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let k = s / 22.0
        let pts: [CGPoint] = [
            (0, 0), (0, 16), (3.5, 12.5), (6.2, 18.5), (8.4, 17.6), (5.8, 11.8), (11, 11.2)
        ].map { CGPoint(x: $0.0 * k, y: $0.1 * k) }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.addPath(path); ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
        ctx.setLineWidth(1.4 * k); ctx.setLineJoin(.round); ctx.strokePath()
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Composites the webcam as a circular picture-in-picture in the bottom-left corner.
    private func compositeWebcam(_ cam: CIImage, over base: CIImage,
                                 outW: CGFloat, outH: CGFloat, style: Style) -> CIImage {
        let ext = cam.extent
        guard ext.width > 0, ext.height > 0 else { return base }
        // Zoom crops a smaller central square (higher zoom = tighter framing).
        let zoom = max(1, style.webcamZoom)
        let side = min(ext.width, ext.height) / zoom
        let cropRect = CGRect(x: ext.midX - side / 2, y: ext.midY - side / 2, width: side, height: side)
        var squared = cam.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        let diameter = outW * style.webcamDiameterFraction
        let scale = diameter / side
        squared = squared.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if style.webcamMirror {
            squared = squared
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: diameter, y: 0))
        }

        if wcMask == nil { wcMask = makeCircleImage(diameter: diameter, fill: true) }
        if wcRing == nil { wcRing = makeCircleImage(diameter: diameter, fill: false) }
        let masked = squared.applyingFilter("CISourceInCompositing",
                                            parameters: [kCIInputBackgroundImageKey: wcMask!])

        // Place so the circle's center sits at the saved normalized position (clamped
        // to keep it fully on screen). CI origin is bottom-left.
        let r = diameter / 2
        let cx = min(max(style.webcamCenterX * outW, r), outW - r)
        let cyTop = min(max(style.webcamCenterY * outH, r), outH - r)
        let originX = cx - r
        let originY = (outH - cyTop) - r
        let placed = masked.transformed(by: CGAffineTransform(translationX: originX, y: originY))
        let ring = wcRing!.transformed(by: CGAffineTransform(translationX: originX, y: originY))
        return ring.composited(over: placed.composited(over: base))
    }

    /// A filled white circle (mask) or a white stroked ring, on a clear background.
    private func makeCircleImage(diameter: CGFloat, fill: Bool) -> CIImage {
        let d = Int(ceil(diameter))
        let ctx = CGContext(data: nil, width: d, height: d, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: d, height: d))
        let inset: CGFloat = fill ? 0 : 2
        let rect = CGRect(x: inset, y: inset, width: diameter - inset * 2, height: diameter - inset * 2)
        ctx.addEllipse(in: rect)
        if fill {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.setLineWidth(4)
            ctx.strokePath()
        }
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Renders a rounded-rect keyboard-shortcut badge like "⌘⇧D".
    private func makeBadge(_ text: String) -> CIImage? {
        let font = NSFont.systemFont(ofSize: 46, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let astr = NSAttributedString(string: text, attributes: attrs)
        let tsize = astr.size()
        let padX: CGFloat = 34, padY: CGFloat = 18
        let w = Int(ceil(tsize.width + padX * 2)), h = Int(ceil(tsize.height + padY * 2))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                           cornerWidth: CGFloat(h) / 2, cornerHeight: CGFloat(h) / 2, transform: nil))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
        ctx.fillPath()

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        astr.draw(at: NSPoint(x: padX, y: padY))
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}

/// Critically-damped spring for smooth camera motion.
private final class SpringCamera {
    var scale: CGFloat = 1, cx: CGFloat = 0.5, cy: CGFloat = 0.5
    private var vScale: CGFloat = 0, vx: CGFloat = 0, vy: CGFloat = 0
    private var started = false

    func step(to target: (scale: CGFloat, cx: CGFloat, cy: CGFloat), dt: CGFloat,
              stiffness: CGFloat, damping: CGFloat) {
        if !started {
            scale = target.scale; cx = target.cx; cy = target.cy
            started = true
            return
        }
        spring(&scale, &vScale, target.scale, dt, stiffness, damping)
        spring(&cx, &vx, target.cx, dt, stiffness, damping)
        spring(&cy, &vy, target.cy, dt, stiffness, damping)
    }

    private func spring(_ x: inout CGFloat, _ v: inout CGFloat, _ target: CGFloat,
                        _ dt: CGFloat, _ k: CGFloat, _ c: CGFloat) {
        let a = -k * (x - target) - c * v
        v += a * dt
        x += v * dt
    }
}
