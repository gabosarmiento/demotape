import Foundation
import AVFoundation
import CoreImage
import AppKit

/// Renders a director's **shot list** from DemoTape's two live feeds at once — the styled screen
/// program and the raw presenter (webcam) — cutting and moving between framings (screen,
/// presenter full/close, split two-shot) with camera moves (push-in, left→right pan) and fades.
///
/// This is the "one coherent authority": the screen feed keeps its own polished click-zoom, and
/// the director composes presenter and split shots around it, so nothing double-zooms.
@available(macOS 12.3, *)
final class DirectorComposer {

    enum ComposerError: LocalizedError {
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
    private let fadeIn = 0.5, fadeOut = 0.8

    /// A forward-only video reader yielding the frame nearest a monotonically increasing time.
    private final class Source {
        let output: AVAssetReaderTrackOutput
        private let reader: AVAssetReader
        var current: CIImage?
        private var currentPTS = -1.0
        private var done = false
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

    /// Composes `shots` over the screen (styled master) + optional webcam into `outURL`.
    func compose(screen screenURL: URL, webcam webcamURL: URL?, cameraOffset: Double,
                 shots: [DirectorShot], brandingURL: URL?, to outURL: URL,
                 progress: ((Double) -> Void)? = nil) throws {
        let screenAsset = AVAsset(url: screenURL)
        guard let vTrack = screenAsset.tracks(withMediaType: .video).first else {
            throw ComposerError.master("no video track")
        }
        let n = vTrack.naturalSize.applying(vTrack.preferredTransform)
        let size = CGSize(width: even(abs(n.width)), height: even(abs(n.height)))
        let fps = vTrack.nominalFrameRate > 1 ? Double(vTrack.nominalFrameRate) : 30.0
        let duration = CMTimeGetSeconds(screenAsset.duration)
        let branding = brandingURL.flatMap { CIImage(contentsOf: $0) }

        // Pass 1: render video to a temp file.
        let tmp = outURL.deletingPathExtension().appendingPathExtension("v.tmp.mp4")
        try renderVideo(screenURL: screenURL, webcamURL: webcamURL, cameraOffset: cameraOffset,
                        shots: shots, size: size, fps: fps, duration: duration, branding: branding,
                        to: tmp, progress: progress)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Pass 2: mux the screen master's audio (passthrough — no re-encode).
        try mux(video: tmp, audioFrom: screenAsset, to: outURL)
        progress?(1.0)
    }

    // MARK: - Video

    private func renderVideo(screenURL: URL, webcamURL: URL?, cameraOffset: Double,
                             shots: [DirectorShot], size: CGSize, fps: Double, duration: Double,
                             branding: CIImage?, to outURL: URL, progress: ((Double) -> Void)?) throws {
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
        guard writer.canAdd(input) else { throw ComposerError.writer("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ComposerError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        guard let screen = Source(url: screenURL) else { throw ComposerError.master("reader failed") }
        let cam = webcamURL.flatMap { Source(url: $0) }
        let frameInterval = 1.0 / fps
        let total = max(1, Int(duration * fps))

        var t = 0.0, frame = 0
        while t < duration {
            let shot = activeShot(shots, at: t)
            let p = shot.end > shot.start ? (t - shot.start) / (shot.end - shot.start) : 0
            let screenImg = screen.frame(at: t)
            let camImg = cam?.frame(at: max(0, t - cameraOffset))

            var img = renderFraming(shot, screen: screenImg, cam: camImg, size: size, progress: p)
            if let branding = branding { img = brandingOverlay(branding, over: img, size: size) }
            img = applyFades(img, at: t, duration: duration, size: size)

            try append(img, at: t, adaptor: adaptor, input: input, writer: writer, size: size)
            t += frameInterval; frame += 1
            if frame % 8 == 0 { progress?(min(0.98, Double(frame) / Double(total) * 0.98)) }
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status != .completed {
            throw ComposerError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    private func activeShot(_ shots: [DirectorShot], at t: Double) -> DirectorShot {
        shots.first { t >= $0.start && t < $0.end }
            ?? DirectorShot(start: t, end: t + 1, framing: .screen, move: .still)
    }

    // MARK: - Framing

    private func renderFraming(_ shot: DirectorShot, screen: CIImage?, cam: CIImage?,
                               size: CGSize, progress p: Double) -> CIImage {
        switch shot.framing {
        case .screen:
            // The styled screen already carries its own motion; don't add more.
            return fit(screen, size)
        case .presenterFull:
            return move(fill(cam, size), shot.move, p, size)
        case .presenterClose:
            let tight = crop(fill(cam, size), scale: 1.5, biasY: 0.60, size: size)  // headroom
            return move(tight, shot.move, p, size)
        case .split:
            return splitScreen(screen: screen, cam: cam, size: size)
        }
    }

    /// Screen on the left (fit), presenter on the right (fill), with a thin gap on black.
    private func splitScreen(screen: CIImage?, cam: CIImage?, size: CGSize) -> CIImage {
        let gap: CGFloat = 8
        let leftW = (size.width * 0.64 - gap / 2).rounded()
        let rightX = leftW + gap
        let rightW = size.width - rightX
        let left = place(screen, mode: .fit, into: CGRect(x: 0, y: 0, width: leftW, height: size.height), size: size)
        let right = place(cam, mode: .fill, into: CGRect(x: rightX, y: 0, width: rightW, height: size.height), size: size)
        return over(right, background: over(left, background: color(.black, size), size: size), size: size)
    }

    // MARK: - Moves

    private func move(_ image: CIImage, _ move: ShotMove, _ p: Double, _ size: CGSize) -> CIImage {
        let e = smootherstep(p)   // slow-in, slow-out — the TV-standard feel
        switch move {
        case .still:
            return image
        case .pushIn:
            // A gentle, continuous push — leads the eye into the cut without calling attention.
            return scalePan(image, scale: 1.0 + 0.05 * CGFloat(e), dx: 0, size: size)
        case .panRight:
            // Sit slightly in, then drift the view left→right — barely perceptible, cinematic.
            let s: CGFloat = 1.10
            let margin = size.width * (s - 1) / (2 * s) * 0.55
            let dx = CGFloat(0.5 - e) * 2 * margin      // +margin → -margin
            return scalePan(image, scale: s, dx: dx, size: size)
        }
    }

    /// Scales `image` about its center and translates by `dx`, cropped to `size`.
    private func scalePan(_ image: CIImage, scale: CGFloat, dx: CGFloat, size: CGSize) -> CIImage {
        let cx = size.width / 2, cy = size.height / 2
        var tr = CGAffineTransform.identity
        tr = tr.translatedBy(x: cx, y: cy)
        tr = tr.scaledBy(x: scale, y: scale)
        tr = tr.translatedBy(x: -cx, y: -cy)
        tr = tr.concatenating(CGAffineTransform(translationX: dx, y: 0))
        return image.transformed(by: tr).cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: - Fades

    private func applyFades(_ image: CIImage, at t: Double, duration: Double, size: CGSize) -> CIImage {
        var alpha: CGFloat = 1
        if t < fadeIn { alpha = CGFloat(t / fadeIn) }
        if t > duration - fadeOut { alpha = min(alpha, CGFloat((duration - t) / fadeOut)) }
        guard alpha < 0.999 else { return image }
        return over(fade(image, alpha: max(0, alpha)), background: color(.black, size), size: size)
    }

    // MARK: - Audio mux (screen master audio, passthrough)

    private func mux(video: URL, audioFrom screenAsset: AVAsset, to outURL: URL) throws {
        try? FileManager.default.removeItem(at: outURL)
        let comp = AVMutableComposition()
        let videoAsset = AVAsset(url: video)
        guard let v = videoAsset.tracks(withMediaType: .video).first,
              let vComp = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ComposerError.writer("mux: no video track") }
        try vComp.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration), of: v, at: .zero)

        if let a = screenAsset.tracks(withMediaType: .audio).first,
           let aComp = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let dur = min(screenAsset.duration, videoAsset.duration)
            try? aComp.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: a, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw ComposerError.writer("mux: no export session")
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        let sema = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sema.signal() }
        sema.wait()
        if export.status != .completed {
            throw ComposerError.writer("mux: \(export.error?.localizedDescription ?? "failed")")
        }
    }

    // MARK: - Image helpers

    private func brandingOverlay(_ logo: CIImage, over base: CIImage, size: CGSize) -> CIImage {
        let targetW = size.width * CGFloat(Settings.brandingWidthFraction)
        let e = logo.extent
        guard e.width > 0 else { return base }
        let s = targetW / e.width
        let scaled = logo.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let cx = size.width * CGFloat(Settings.brandingCenterX)
        let cyTop = size.height * CGFloat(Settings.brandingCenterY)
        let x = cx - scaled.extent.width / 2 - scaled.extent.minX
        let y = (size.height - cyTop) - scaled.extent.height / 2 - scaled.extent.minY
        return over(scaled.transformed(by: CGAffineTransform(translationX: x, y: y)), background: base, size: size)
    }

    private enum PlaceMode { case fit, fill }
    private func place(_ image: CIImage?, mode: PlaceMode, into rect: CGRect, size: CGSize) -> CIImage {
        guard let image = image else { return color(.clear, size) }
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return color(.clear, size) }
        let s = mode == .fit ? min(rect.width / e.width, rect.height / e.height)
                             : max(rect.width / e.width, rect.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let tx = rect.minX + (rect.width - scaled.extent.width) / 2 - scaled.extent.minX
        let ty = rect.minY + (rect.height - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .cropped(to: rect)
    }

    /// Aspect-fill then zoom in by `scale` about a center biased vertically (biasY in 0…1 from
    /// bottom), for a tighter close-up with headroom.
    private func crop(_ image: CIImage, scale: CGFloat, biasY: CGFloat, size: CGSize) -> CIImage {
        let cx = size.width / 2, cy = size.height * biasY
        var tr = CGAffineTransform.identity
        tr = tr.translatedBy(x: cx, y: cy)
        tr = tr.scaledBy(x: scale, y: scale)
        tr = tr.translatedBy(x: -cx, y: -cy)
        return image.transformed(by: tr).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Smootherstep (Ken Perlin): zero velocity AND acceleration at both ends — the gentlest,
    /// most "broadcast" ramp, with no visible start/stop snap.
    private func smootherstep(_ p: Double) -> Double {
        let x = min(max(p, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

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
        place(image, mode: .fit, into: CGRect(origin: .zero, size: size), size: size)
    }
    private func fill(_ image: CIImage?, _ size: CGSize) -> CIImage {
        place(image, mode: .fill, into: CGRect(origin: .zero, size: size), size: size)
    }

    private func append(_ image: CIImage, at seconds: Double, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                        input: AVAssetWriterInput, writer: AVAssetWriter, size: CGSize) throws {
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing { throw ComposerError.writer("writer status \(writer.status.rawValue)") }
            usleep(1500)
        }
        guard let pool = adaptor.pixelBufferPool else { throw ComposerError.writer("no pixel buffer pool") }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buffer = pb else { throw ComposerError.writer("no pixel buffer") }
        ci.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: rgb)
        if !adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) {
            throw ComposerError.writer("append failed at \(seconds)s")
        }
    }

    private func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
}
