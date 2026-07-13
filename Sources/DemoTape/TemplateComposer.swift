import Foundation
import AVFoundation
import CoreImage
import AppKit

/// The auto-edit engine. Interprets a template's `Timeline` frame by frame: it advances through
/// the source footage (screen + optional webcam angle) on a speed-mapped clock, and stacks the
/// active events (zoom, punch, flip, slide, blur, shake, float, fades, angle switches) with
/// easing onto each frame. Renders video first (single input → no interleave deadlock), then
/// muxes the source audio, time-scaled to match any speed ramps.
@available(macOS 12.3, *)
final class TemplateComposer {

    enum ComposerError: Error, LocalizedError {
        case master(String), writer(String)
        var errorDescription: String? {
            switch self {
            case .master(let m): return "Couldn't read the recording: \(m)"
            case .writer(let m): return "Couldn't write the video: \(m)"
            }
        }
    }

    private let ci: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: dev) }
        return CIContext()
    }()
    private let rgb = CGColorSpaceCreateDeviceRGB()

    /// A forward-only source that yields the frame nearest a monotonically increasing time.
    private final class Source {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        var current: CIImage?
        var currentPTS = -1.0
        var done = false
        init?(url: URL) {
            let asset = AVAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first,
                  let reader = try? AVAssetReader(asset: asset) else { return nil }
            let out = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { return nil }
            reader.add(out); reader.startReading()
            self.reader = reader; self.output = out
        }
        func frame(at t: Double) -> CIImage? {
            while !done && currentPTS < t {
                if let sb = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
                    current = CIImage(cvImageBuffer: pb)
                    currentPTS = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                } else { done = true }
            }
            return current
        }
    }

    func compose(master masterURL: URL, cam camURL: URL?, branding brandingURL: URL?,
                 template: VideoTemplate, to outURL: URL,
                 progress: ((Double) -> Void)? = nil) throws {

        let masterAsset = AVAsset(url: masterURL)
        guard let vTrack = masterAsset.tracks(withMediaType: .video).first else {
            throw ComposerError.master("no video track")
        }
        let n = vTrack.naturalSize.applying(vTrack.preferredTransform)
        let size = CGSize(width: even(abs(n.width)), height: even(abs(n.height)))
        let fps = vTrack.nominalFrameRate > 1 ? Double(vTrack.nominalFrameRate) : 30.0
        let frameInterval = 1.0 / fps
        let sourceDuration = CMTimeGetSeconds(masterAsset.duration)

        let hasWebcam = camURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let timeline = template.plan(PlanContext(sourceDuration: sourceDuration, hasWebcam: hasWebcam))
        Log.write("TemplateComposer: \(template.id) events=\(timeline.events.count) size=\(size) dur=\(sourceDuration)")

        // Speed map: source-time segments with a playback factor (default 1).
        let speedSegments = buildSpeedMap(events: timeline.events, duration: sourceDuration)

        // --- Pass 1: render video only to a temp file (no audio → no interleave deadlock). ---
        let tmpVideo = outURL.deletingPathExtension().appendingPathExtension("v.tmp.mp4")
        try renderVideo(masterURL: masterURL, camURL: hasWebcam ? camURL : nil, size: size, fps: fps,
                        frameInterval: frameInterval, sourceDuration: sourceDuration,
                        timeline: timeline, brandingURL: brandingURL, to: tmpVideo, progress: progress)

        // --- Pass 2: mux source audio, time-scaled to the speed map. ---
        defer { try? FileManager.default.removeItem(at: tmpVideo) }
        try muxAudio(video: tmpVideo, master: masterAsset, masterURL: masterURL,
                     speedSegments: speedSegments, to: outURL)
        progress?(1.0)
    }

    // MARK: - Pass 1: video

    private func renderVideo(masterURL: URL, camURL: URL?, size: CGSize, fps: Double,
                             frameInterval: Double, sourceDuration: Double, timeline: Timeline,
                             brandingURL: URL?, to outURL: URL, progress: ((Double) -> Void)?) throws {
        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height) * 8,
                AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)])
        guard writer.canAdd(input) else { throw ComposerError.writer("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ComposerError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        guard let screen = Source(url: masterURL) else { throw ComposerError.master("reader failed") }
        let cam = camURL.flatMap { Source(url: $0) }

        let est = estimatedOutputDuration(timeline: timeline, duration: sourceDuration)
        let totalFrames = max(1, Int(est * fps))

        var st = 0.0, ot = 0.0, frame = 0
        while st < sourceDuration {
            let angle = activeAngle(timeline, at: st)
            let src = (angle == .webcam ? cam : screen) ?? screen
            let raw = src.frame(at: st)
            let img = applyEffects(raw: raw, angle: angle, size: size, timeline: timeline, st: st, frame: frame)
            try append(img, at: ot, adaptor: adaptor, input: input, writer: writer, size: size)

            let sp = speed(timeline, at: st)
            st += sp * frameInterval
            ot += frameInterval; frame += 1
            if frame % 8 == 0 { progress?(min(0.98, Double(frame) / Double(totalFrames) * 0.98)) }
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status != .completed {
            throw ComposerError.writer(writer.error?.localizedDescription ?? "unknown")
        }
    }

    // MARK: - Effects

    private func activeAngle(_ tl: Timeline, at st: Double) -> Angle {
        var angle: Angle = .screen
        var best = -1.0
        for e in tl.events {
            if case .switchAngle(let a) = e.kind, e.start <= st, e.start >= best { angle = a; best = e.start }
        }
        return angle
    }

    private func speed(_ tl: Timeline, at st: Double) -> Double {
        var f = 1.0
        for e in tl.events {
            if case .speedRamp(let factor) = e.kind, st >= e.start, st < e.end { f = max(f, factor) }
        }
        return f
    }

    /// Fold zoomIn/zoomOut into a single base scale at time st (ramp, then hold).
    private func baseScale(_ tl: Timeline, at st: Double) -> CGFloat {
        var current: CGFloat = 1
        let zooms = tl.events.filter {
            if case .zoomIn = $0.kind { return $0.start <= st }
            if case .zoomOut = $0.kind { return $0.start <= st }
            return false
        }.sorted { $0.start < $1.start }
        for e in zooms {
            let target: CGFloat
            if case .zoomIn(let a) = e.kind { target = a }
            else if case .zoomOut(let a) = e.kind { target = a }
            else { continue }
            if st >= e.end { current = target }
            else {
                let p = CGFloat(e.easing.apply((st - e.start) / e.duration))
                current = current + (target - current) * p
                break
            }
        }
        return current
    }

    private func applyEffects(raw: CIImage?, angle: Angle, size: CGSize, timeline tl: Timeline,
                              st: Double, frame: Int) -> CIImage {
        let content = angle == .webcam ? fill(raw, size) : fit(raw, size)
        var scale = baseScale(tl, at: st)
        var flipX: CGFloat = 1, flipY: CGFloat = 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        var rotation: CGFloat = 0
        var blur: CGFloat = 0
        var alpha: CGFloat = 1

        // Fold blur (in/out ramp+hold), like scale.
        var blurCur: CGFloat = 0
        let blurEvents = tl.events.filter {
            (($0.kind == .blurIn || $0.kind == .blurOut)) && $0.start <= st
        }.sorted { $0.start < $1.start }
        let maxBlur: CGFloat = 20
        for e in blurEvents {
            let target: CGFloat = (e.kind == .blurIn) ? maxBlur : 0
            if st >= e.end { blurCur = target }
            else { blurCur += (target - blurCur) * CGFloat(e.easing.apply((st - e.start) / e.duration)); break }
        }
        blur = blurCur

        for e in tl.events where st >= e.start && st < e.end {
            let p = e.easing.apply((st - e.start) / max(e.duration, 0.0001))
            switch e.kind {
            case .punchIn(let a):
                let bump = sin(Double.pi * p)                 // 0→1→0
                scale *= 1 + (a - 1) * CGFloat(bump)
            case .flipH: flipX = -1
            case .flipV: flipY = -1
            case .slide(let dir):
                let off = CGFloat(1 - p)                      // fully offset → settled
                switch dir {
                case .left:  dx = -size.width * off
                case .right: dx =  size.width * off
                case .up:    dy =  size.height * off
                case .down:  dy = -size.height * off
                }
            case .fadeIn:      alpha = min(alpha, CGFloat(p))
            case .fadeToBlack: alpha = min(alpha, CGFloat(1 - p))
            case .shake(let amp):
                let j = SeededRNG(seed: UInt64(frame) &* 2654435761)
                var r = j
                dx += CGFloat(r.next(in: Int(-amp)...Int(amp)))
                dy += CGFloat(r.next(in: Int(-amp)...Int(amp)))
            case .float(let deg):
                rotation += CGFloat(sin(2 * Double.pi * (st - e.start) / max(e.duration, 1)) * deg) * .pi / 180
            case .pan(let fx, let fy):
                // Sweep the zoomed frame from one side to the other over the event.
                dx += CGFloat(0.5 - p) * fx * size.width
                dy += CGFloat(0.5 - p) * fy * size.height
            default: break
            }
        }

        // Compose transform around the center.
        let cx = size.width / 2, cy = size.height / 2
        var tr = CGAffineTransform.identity
        tr = tr.translatedBy(x: cx, y: cy)
        tr = tr.rotated(by: rotation)
        tr = tr.scaledBy(x: flipX * scale, y: flipY * scale)
        tr = tr.translatedBy(x: -cx, y: -cy)
        tr = tr.concatenating(CGAffineTransform(translationX: dx, y: dy))
        var img = content.transformed(by: tr)
        if blur > 0.4 {
            img = img.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
        }

        // Never reveal black behind moved/scaled content: fill the canvas with a blurred,
        // darkened, zoomed copy of the same frame (the familiar social-video backdrop).
        let bg = blurredBackground(raw, size: size)
        var composed = over(img, background: bg, size: size)

        // Fade in / to black darkens the whole composited frame (intentional).
        if alpha < 0.999 {
            composed = over(fade(composed, alpha: alpha), background: color(.black, size), size: size)
        }
        return composed
    }

    /// A blurred, slightly darkened, aspect-fill copy of the frame — the backdrop that keeps
    /// transitions from ever showing black.
    private func blurredBackground(_ raw: CIImage?, size: CGSize) -> CIImage {
        let filled = fill(raw, size)
        let blurred = filled.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 36])
            .cropped(to: CGRect(origin: .zero, size: size))
        // Darken a touch so the sharp foreground stands out.
        return blurred.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12])
    }

    // MARK: - Pass 2: audio mux (time-scaled to the speed map)

    private func muxAudio(video videoURL: URL, master: AVAsset, masterURL: URL,
                          speedSegments: [(start: Double, end: Double, factor: Double)],
                          to outURL: URL) throws {
        try? FileManager.default.removeItem(at: outURL)
        let comp = AVMutableComposition()
        let videoAsset = AVAsset(url: videoURL)
        guard let vTrack = videoAsset.tracks(withMediaType: .video).first,
              let compVideo = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ComposerError.writer("mux: no video track") }
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration),
                                      of: vTrack, at: .zero)

        var hasRamp = false
        if let aTrack = master.tracks(withMediaType: .audio).first,
           let compAudio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            var cursor = CMTime.zero
            let scale: CMTimeScale = 44100
            for seg in speedSegments {
                let srcRange = CMTimeRange(start: CMTime(seconds: seg.start, preferredTimescale: scale),
                                           duration: CMTime(seconds: seg.end - seg.start, preferredTimescale: scale))
                try? compAudio.insertTimeRange(srcRange, of: aTrack, at: cursor)
                let outDur = (seg.end - seg.start) / seg.factor
                if seg.factor != 1.0 {
                    hasRamp = true
                    compAudio.scaleTimeRange(CMTimeRange(start: cursor, duration: srcRange.duration),
                                             toDuration: CMTime(seconds: outDur, preferredTimescale: scale))
                }
                cursor = CMTimeAdd(cursor, CMTime(seconds: outDur, preferredTimescale: scale))
            }
        }

        // Passthrough is fast and lossless when audio wasn't time-scaled; otherwise re-encode.
        let preset = hasRamp ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
        guard let export = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw ComposerError.writer("mux: no export session")
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        let sema = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sema.signal() }
        sema.wait()
        if export.status != .completed {
            throw ComposerError.writer("mux: \(export.error?.localizedDescription ?? "export failed")")
        }
    }

    // MARK: - Speed map

    private func buildSpeedMap(events: [EditEvent], duration: Double)
        -> [(start: Double, end: Double, factor: Double)] {
        // Collect ramp windows, then split [0,duration] into segments at every boundary.
        var bounds: Set<Double> = [0, duration]
        var ramps: [(Double, Double, Double)] = []
        for e in events {
            if case .speedRamp(let f) = e.kind {
                let s = max(0, e.start), en = min(duration, e.end)
                if en > s { ramps.append((s, en, f)); bounds.insert(s); bounds.insert(en) }
            }
        }
        let sorted = bounds.sorted()
        var segs: [(start: Double, end: Double, factor: Double)] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            guard b > a else { continue }
            let mid = (a + b) / 2
            var f = 1.0
            for r in ramps where mid >= r.0 && mid < r.1 { f = max(f, r.2) }
            segs.append((a, b, f))
        }
        return segs.isEmpty ? [(0, duration, 1)] : segs
    }

    private func estimatedOutputDuration(timeline: Timeline, duration: Double) -> Double {
        let segs = buildSpeedMap(events: timeline.events, duration: duration)
        return segs.reduce(0) { $0 + ($1.end - $1.start) / $1.factor }
    }

    // MARK: - Image helpers

    private func fade(_ image: CIImage, alpha: CGFloat) -> CIImage {
        let f = CIFilter(name: "CIColorMatrix")!
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: 0, y: 0, z: 0, w: alpha), forKey: "inputAVector")
        return f.outputImage ?? image
    }
    private func over(_ image: CIImage, background: CIImage, size: CGSize) -> CIImage {
        let f = CIFilter(name: "CISourceOverCompositing")!
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(background, forKey: kCIInputBackgroundImageKey)
        return (f.outputImage ?? image).cropped(to: CGRect(origin: .zero, size: size))
    }
    private func color(_ c: NSColor, _ size: CGSize) -> CIImage {
        CIImage(color: CIColor(color: c) ?? CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
    private func fit(_ image: CIImage?, _ size: CGSize) -> CIImage {
        guard let image = image else { return color(.black, size) }
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return color(.black, size) }
        let s = min(size.width / e.width, size.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let tx = (size.width - scaled.extent.width) / 2 - scaled.extent.minX
        let ty = (size.height - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }
    private func fill(_ image: CIImage?, _ size: CGSize) -> CIImage {
        guard let image = image else { return color(.black, size) }
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return color(.black, size) }
        let s = max(size.width / e.width, size.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let tx = (size.width - scaled.extent.width) / 2 - scaled.extent.minX
        let ty = (size.height - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private func append(_ image: CIImage, at seconds: Double, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                        input: AVAssetWriterInput, writer: AVAssetWriter, size: CGSize) throws {
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing {
                throw ComposerError.writer(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
            }
            usleep(1500)
        }
        guard let pool = adaptor.pixelBufferPool else { throw ComposerError.writer("no pixel buffer pool") }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buffer = pb else { throw ComposerError.writer("no pixel buffer") }
        ci.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: rgb)
        if !adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) {
            throw ComposerError.writer(writer.error?.localizedDescription ?? "append failed at \(seconds)s")
        }
    }

    private func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
}
