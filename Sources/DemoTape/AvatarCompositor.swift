import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import AppKit

/// Removes the avatar video's background so it can be composited over the screen recording.
/// Isolated behind a protocol so a transparent-WebM (or HEVC-alpha) path can be added later
/// without touching the compositor.
protocol BackgroundRemover {
    /// Returns the frame with its background turned transparent (premultiplied alpha).
    func removeBackground(_ frame: CIImage) -> CIImage
}

/// Keeps the avatar frame as-is. Used for photo avatars, where HeyGen renders the person over
/// their original photo background (not a green screen) — so we present them as a webcam-style
/// PiP instead of keying.
final class PassthroughRemover: BackgroundRemover {
    func removeBackground(_ frame: CIImage) -> CIImage { frame }
}

/// Chroma-keys out a solid background color (default HeyGen green #00B140) using a Core Image
/// color cube — dependency-free and works on Intel/Monterey. Includes light green-spill
/// suppression on the retained pixels.
final class ChromaKeyRemover: BackgroundRemover {
    private let cube: CIFilter
    init(hex: String = "#00B140") {
        self.cube = ChromaKeyRemover.makeCube(hex: hex)
    }

    func removeBackground(_ frame: CIImage) -> CIImage {
        cube.setValue(frame, forKey: kCIInputImageKey)
        let keyed = cube.outputImage ?? frame
        // Reduce green spill on edges: pull green down toward the max of red/blue.
        return keyed.applyingFilter("CIColorMatrix", parameters: [
            "inputGVector": CIVector(x: 0, y: 0.85, z: 0, w: 0)
        ])
    }

    /// Builds a 64³ color cube that sets alpha to 0 for pixels near the key hue.
    private static func makeCube(hex: String) -> CIFilter {
        let (kr, kg, kb) = rgb(from: hex)
        var keyH: CGFloat = 0, keyS: CGFloat = 0, keyV: CGFloat = 0
        NSColor(red: kr, green: kg, blue: kb, alpha: 1)
            .usingColorSpace(.deviceRGB)?
            .getHue(&keyH, saturation: &keyS, brightness: &keyV, alpha: nil)

        let dim = 64
        var data = [Float](repeating: 0, count: dim * dim * dim * 4)
        var offset = 0
        for b in 0..<dim {
            for g in 0..<dim {
                for r in 0..<dim {
                    let red = CGFloat(r) / CGFloat(dim - 1)
                    let green = CGFloat(g) / CGFloat(dim - 1)
                    let blue = CGFloat(b) / CGFloat(dim - 1)
                    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
                    NSColor(red: red, green: green, blue: blue, alpha: 1)
                        .usingColorSpace(.deviceRGB)?
                        .getHue(&h, saturation: &s, brightness: &v, alpha: nil)
                    // Transparent when the hue is close to the key and it's saturated/bright.
                    let hueClose = abs(h - keyH) < 0.10 || abs(h - keyH) > 0.90
                    let alpha: Float = (hueClose && s > 0.35 && v > 0.25) ? 0 : 1
                    data[offset + 0] = Float(red) * alpha
                    data[offset + 1] = Float(green) * alpha
                    data[offset + 2] = Float(blue) * alpha
                    data[offset + 3] = alpha
                    offset += 4
                }
            }
        }
        let cubeData = data.withUnsafeBufferPointer { Data(buffer: $0) }
        let f = CIFilter(name: "CIColorCube")!
        f.setValue(dim, forKey: "inputCubeDimension")
        f.setValue(cubeData, forKey: "inputCubeData")
        return f
    }

    private static func rgb(from hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return (0, 0.69, 0.25) }
        return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }
}

/// Composites a background-removed avatar video as a corner presenter over the screen video,
/// preserving the screen video's (ElevenLabs) audio. Mirrors CaptionBurner's reader→CI→writer
/// pipeline: H.264 High + faststart, original resolution/duration.
final class AvatarCompositor {

    enum CompositorError: LocalizedError {
        case noVideoTrack, failed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The video has no video track."
            case .failed(let m): return "Avatar compositing failed: \(m)"
            }
        }
    }

    struct Layout {
        /// `circle` = webcam-style round PiP (photo avatars, keeps their background).
        /// `cutout` = chroma-keyed transparent cutout placed in a corner (green-screen avatars).
        enum Shape { case circle, cutout }
        var shape: Shape = .circle

        // Circle placement matches DemoTape's webcam overlay geometry (normalized, top-left
        // origin), so the avatar can visually take the webcam's place.
        var centerX: CGFloat = 0.14          // fraction of width
        var centerY: CGFloat = 0.82          // fraction of height (top-left origin)
        var diameterFraction: CGFloat = 0.18 // fraction of width

        // How much of the circle the person fills (1.0 = fit exactly; <1 = more zoomed out /
        // more headroom). Default leaves a little breathing room so the face isn't too close.
        var subjectScale: CGFloat = 0.92

        // Cutout placement (corner).
        var position: AvatarPosition = .bottomRight
        var sizeFraction: CGFloat = 0.34     // fraction of height
        var margin: CGFloat = 0.03           // fraction of height
    }

    private let remover: BackgroundRemover
    private let ciContext: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(remover: BackgroundRemover) { self.remover = remover }

    /// Places the keyed avatar frame at a constant size/corner over the screen frame.
    /// `avatar` is already background-removed. Auto-scaled by height and centered horizontally
    /// within its slot, so differing source framings land consistently.
    private func place(_ avatar: CIImage, over screen: CIImage, size: CGSize, layout: Layout) -> CIImage {
        switch layout.shape {
        case .circle: return placeCircle(avatar, over: screen, size: size, layout: layout)
        case .cutout: return placeCutout(avatar, over: screen, size: size, layout: layout)
        }
    }

    /// Webcam-style circular PiP: aspect-fill the avatar into the circle (cover, centered with a
    /// slight top bias for headroom) and mask to a circle, placed at the webcam's normalized
    /// center. Clean fill relies on a well-framed source — photo avatars are padded with
    /// headroom before upload (see AvatarProvider flow) so this doesn't crop the face.
    private func placeCircle(_ avatar: CIImage, over screen: CIImage, size: CGSize, layout: Layout) -> CIImage {
        let e = avatar.extent
        guard e.width > 0, e.height > 0 else { return screen }
        let d = size.width * layout.diameterFraction
        let box = CGRect(x: 0, y: 0, width: d, height: d)
        let cx = layout.centerX * size.width
        let cyTop = layout.centerY * size.height
        let ox = cx - d / 2
        let oy = (size.height - cyTop) - d / 2

        // Frosted disc: a blurred crop of the screen behind the circle. A chroma-keyed avatar
        // (transparent background) then sits cleanly on this disc instead of showing the desktop
        // through it; an opaque avatar simply covers it.
        let discBG = screen.cropped(to: CGRect(x: ox, y: oy, width: d, height: d))
            .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: d * 0.08])
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.05])
            .cropped(to: box)

        // Avatar: aspect-fill the disc, top-biased crop so the head stays in frame.
        let scale = max(d / e.width, d / e.height)
        var img = avatar.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let cropX = (img.extent.width - d) / 2
        let cropY = max(0, img.extent.height - d)
        let person = img.cropped(to: CGRect(x: cropX, y: cropY, width: d, height: d))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

        var combined = person.composited(over: discBG).cropped(to: box)
        if let m = CIFilter(name: "CIRoundedRectangleGenerator") {
            m.setValue(CIVector(cgRect: box), forKey: "inputExtent")
            m.setValue(d / 2, forKey: "inputRadius")
            m.setValue(CIColor.white, forKey: "inputColor")
            if let mask = m.outputImage?.cropped(to: box) {
                combined = combined.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputMaskImageKey: mask])
            }
        }
        return combined.transformed(by: CGAffineTransform(translationX: ox, y: oy)).composited(over: screen)
    }

    /// Chroma-keyed cutout placed in a corner, scaled by height.
    private func placeCutout(_ avatar: CIImage, over screen: CIImage, size: CGSize, layout: Layout) -> CIImage {
        let e = avatar.extent
        guard e.width > 0, e.height > 0 else { return screen }
        let targetH = size.height * layout.sizeFraction
        let scale = targetH / e.height
        var scaled = avatar.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        scaled = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        let w = scaled.extent.width
        let margin = size.height * layout.margin
        let x = (layout.position == .bottomLeft) ? margin : (size.width - w - margin)
        let placed = scaled.transformed(by: CGAffineTransform(translationX: x, y: margin))
        return placed.composited(over: screen)
    }

    /// Renders a single preview frame (screen with the avatar placed) as an NSImage.
    func previewFrame(screen: URL, avatar: URL, at seconds: Double, layout: Layout) -> NSImage? {
        let sAsset = AVAsset(url: screen), aAsset = AVAsset(url: avatar)
        guard let sTrack = sAsset.tracks(withMediaType: .video).first else { return nil }
        let size = sTrack.naturalSize
        let sGen = AVAssetImageGenerator(asset: sAsset); sGen.appliesPreferredTrackTransform = true
        let aGen = AVAssetImageGenerator(asset: aAsset); aGen.appliesPreferredTrackTransform = true
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let sCG = try? sGen.copyCGImage(at: t, actualTime: nil),
              let aCG = try? aGen.copyCGImage(at: t, actualTime: nil) else { return nil }
        let keyed = remover.removeBackground(CIImage(cgImage: aCG))
        let composed = place(keyed, over: CIImage(cgImage: sCG), size: size, layout: layout)
        guard let out = ciContext.createCGImage(composed, from: CGRect(origin: .zero, size: size)) else { return nil }
        return NSImage(cgImage: out, size: size)
    }

    /// Composites `avatar` over `screen` → `outURL`. Screen audio (ElevenLabs) is preserved.
    /// Avatar shorter than the screen: its last frame is held. Longer: clamped to the screen.
    func compose(screen: URL, avatar: URL, to outURL: URL, layout: Layout,
                 isCancelled: @escaping () -> Bool = { false }) throws {
        let sAsset = AVAsset(url: screen)
        let aAsset = AVAsset(url: avatar)
        guard let sTrack = sAsset.tracks(withMediaType: .video).first else { throw CompositorError.noVideoTrack }
        guard let aTrack = aAsset.tracks(withMediaType: .video).first else { throw CompositorError.noVideoTrack }
        let size = sTrack.naturalSize

        let sReader = try AVAssetReader(asset: sAsset)
        let sOut = AVAssetReaderTrackOutput(track: sTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        sOut.alwaysCopiesSampleData = false
        sReader.add(sOut)

        let aReader = try AVAssetReader(asset: aAsset)
        let aOut = AVAssetReaderTrackOutput(track: aTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        aOut.alwaysCopiesSampleData = false
        aReader.add(aOut)

        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * 4),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true]])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(vIn)

        // Preserve the screen video's audio (the ElevenLabs narration) as AAC.
        var aAudioReader: AVAssetReader?, aAudioOut: AVAssetReaderTrackOutput?, audioIn: AVAssetWriterInput?
        if let audioTrack = sAsset.tracks(withMediaType: .audio).first {
            let ar = try AVAssetReader(asset: sAsset)
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            ar.add(out)
            let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
            ain.expectsMediaDataInRealTime = false
            writer.add(ain)
            aAudioReader = ar; aAudioOut = out; audioIn = ain
        }

        guard sReader.startReading() else { throw CompositorError.failed(sReader.error?.localizedDescription ?? "screen reader") }
        aReader.startReading()
        guard writer.startWriting() else { throw CompositorError.failed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let audioGroup = DispatchGroup()
        if let ar = aAudioReader, let out = aAudioOut, let ain = audioIn {
            ar.startReading(); audioGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while ar.status == .reading {
                    if writer.status != .writing { break }
                    guard let sb = out.copyNextSampleBuffer() else { break }
                    while !ain.isReadyForMoreMediaData { if writer.status != .writing { break }; usleep(1000) }
                    if writer.status != .writing { break }
                    ain.append(sb)
                }
                ain.markAsFinished(); audioGroup.leave()
            }
        }

        // Keyed avatar frame cache advanced to keep pace with the screen timeline.
        var avatarKeyed: CIImage?
        var avatarPTS = -1.0
        var avatarDone = false
        func avatarFrame(at t: Double) -> CIImage? {
            while !avatarDone && avatarPTS < t {
                if let sb = aOut.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
                    avatarKeyed = remover.removeBackground(CIImage(cvImageBuffer: pb))
                    avatarPTS = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                } else { avatarDone = true }   // hold last keyed frame
            }
            return avatarKeyed
        }

        let queue = DispatchQueue(label: "pro.demotape.avatar-composite")
        let done = DispatchSemaphore(value: 0)
        var renderError: Error?
        vIn.requestMediaDataWhenReady(on: queue) { [self] in
            while vIn.isReadyForMoreMediaData {
                if isCancelled() { renderError = AvatarProviderError.cancelled; vIn.markAsFinished(); done.signal(); return }
                if writer.status != .writing { done.signal(); return }
                guard let sample = sOut.copyNextSampleBuffer() else { vIn.markAsFinished(); done.signal(); return }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let screenImage = CIImage(cvImageBuffer: pb)
                let composed: CIImage
                if let keyed = avatarFrame(at: CMTimeGetSeconds(pts)) {
                    composed = place(keyed, over: screenImage, size: size, layout: layout)
                } else {
                    composed = screenImage
                }
                guard let pool = adaptor.pixelBufferPool else { continue }
                var outBuf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                guard let outBuf = outBuf else { continue }
                ciContext.render(composed, to: outBuf,
                                 bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
                adaptor.append(outBuf, withPresentationTime: pts)
            }
        }
        done.wait()
        vIn.markAsFinished()
        audioGroup.wait()
        aReader.cancelReading()

        if let e = renderError { throw e }
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        guard writer.status == .completed else {
            throw CompositorError.failed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        Log.write("AvatarCompositor: \(outURL.lastPathComponent)")
    }
}
