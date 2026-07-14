import Foundation
import AVFoundation
import CoreImage
import CoreText
import CoreVideo
import CoreGraphics
import Metal
import AppKit

/// Burns styled captions into a video (`…captioned.mp4`, H.264 + AAC, faststart). Supports
/// animated word-timed styles (pop-in, karaoke highlight) and static phrase styles, drawn with
/// Core Text (thread-safe). Frames are cached per word-state, so we only redraw on word changes.
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

    // Per-frame render cache (only regenerates when the visible word-state changes).
    private var cacheKey = ""
    private var cacheImage: CIImage?
    private var cacheOrigin: CGPoint = .zero

    func burn(video: URL, cues: [CaptionCue], style: CaptionStyle, to outURL: URL) throws {
        let asset = AVAsset(url: video)
        guard let vTrack = asset.tracks(withMediaType: .video).first else { throw BurnError.noVideoTrack }
        let size = vTrack.naturalSize
        let aspect = size.height > 0 ? size.width / size.height : 1.78
        let maxWords = style.maxWordsPerLine(forAspect: aspect)
        let sorted = cues.sorted { $0.start < $1.start }

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

        // Audio → AAC (concurrent pump).
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

                if let (overlay, origin) = captionOverlay(at: t, cues: sorted, style: style,
                                                          size: size, maxWords: maxWords) {
                    image = overlay.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
                        .composited(over: image)
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
        Log.write("CaptionBurner: \(sorted.count) cues, style=\(style.id) -> \(outURL.lastPathComponent)")
    }

    // MARK: - Per-frame caption overlay (cached by word-state)

    private func captionOverlay(at t: Double, cues: [CaptionCue], style: CaptionStyle,
                                size: CGSize, maxWords: Int) -> (CIImage, CGPoint)? {
        guard let idx = cues.firstIndex(where: { t >= $0.start && t < $0.end }) else {
            cacheKey = ""; return nil
        }
        let cue = cues[idx]
        let words = wordsForCue(cue)
        guard !words.isEmpty else { cacheKey = ""; return nil }

        // Never dump a whole cue over the frame. Split the cue into small windows that hold at
        // most `maxLines` lines and step through them as the words are spoken. On a regular
        // (wide) video that's ~2 short lines; on mobile it's 1–2 words per line.
        let aspect = size.height > 0 ? size.width / size.height : 1.78
        let maxLines = 2
        let windowSize = max(1, maxWords * maxLines)
        let (windowIdx, windowWords) = Self.window(for: t, in: words, size: windowSize)
        guard !windowWords.isEmpty else { cacheKey = ""; return nil }

        // Within the window: animated pop-in styles reveal words as spoken; everything else
        // shows the whole window and colors the active word.
        let visible: [CaptionWord] = (style.animated && !style.revealFuture)
            ? windowWords.filter { $0.start <= t } : windowWords
        guard !visible.isEmpty else { cacheKey = ""; return nil }
        let activeIdx = windowWords.firstIndex { $0.start <= t && t < $0.end } ?? -1

        let key = style.animated ? "\(idx)|\(windowIdx)|\(visible.count)|\(activeIdx)"
                                  : "\(idx)|\(windowIdx)"
        if key == cacheKey, let img = cacheImage { return (img, cacheOrigin) }

        guard let (cg, blockSize) = drawBlock(words: visible, style: style, t: t,
                                              videoSize: size, maxWords: maxWords) else { return nil }
        let x = (size.width - blockSize.width) / 2
        // Position by aspect, not just by style: regular videos always sit at the bottom-center;
        // tall/mobile videos may use the style's higher placement.
        let position: CaptionPosition = aspect > 1.05 ? .bottom : style.position
        let y: CGFloat
        switch position {
        case .center:     y = (size.height - blockSize.height) / 2
        case .lowerThird: y = size.height * 0.16
        case .bottom:     y = size.height * 0.07
        }
        let img = CIImage(cgImage: cg)
        cacheKey = key; cacheImage = img; cacheOrigin = CGPoint(x: x.rounded(), y: y.rounded())
        return (img, cacheOrigin)
    }

    /// Splits a cue's words into consecutive fixed-size windows and returns the one that should be
    /// on screen at time `t` (the first window whose last word hasn't finished, else the last).
    static func window(for t: Double, in words: [CaptionWord], size: Int) -> (Int, [CaptionWord]) {
        let n = words.count
        guard n > size else { return (0, words) }
        var c = 0
        var lo = 0
        while lo < n {
            let hi = min(lo + size, n)
            let slice = Array(words[lo..<hi])
            if let last = slice.last, t < last.end { return (c, slice) }
            lo = hi; c += 1
        }
        let start = (c - 1) * size
        return (c - 1, Array(words[start..<n]))
    }

    /// Per-cue words with timing — real word timestamps when present, otherwise synthesized
    /// evenly across the cue so animation still works on older transcripts.
    private func wordsForCue(_ cue: CaptionCue) -> [CaptionWord] {
        if let w = cue.words, !w.isEmpty { return w }
        let toks = cue.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !toks.isEmpty else { return [] }
        let dur = max(0.01, cue.end - cue.start)
        let per = dur / Double(toks.count)
        return toks.enumerated().map {
            CaptionWord(text: $1, start: cue.start + Double($0) * per, end: cue.start + Double($0 + 1) * per)
        }
    }

    // MARK: - Drawing

    private func drawBlock(words visible: [CaptionWord], style: CaptionStyle,
                           t: Double, videoSize: CGSize, maxWords: Int) -> (CGImage, CGSize)? {
        let fontSize = max(20, videoSize.height * (style.animated ? 0.062 : 0.05))
        let font = CTFontCreateWithName(style.fontName as CFString, fontSize, nil)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = (ascent + descent) * 1.18
        let padX = fontSize * 0.55, padY = fontSize * 0.34

        // Chunk visible words into lines.
        var lines: [[CaptionWord]] = []
        var i = 0
        while i < visible.count {
            lines.append(Array(visible[i..<min(i + maxWords, visible.count)]))
            i += maxWords
        }
        guard !lines.isEmpty else { return nil }

        // Build a CTLine per row and measure.
        let ctLines: [CTLine] = lines.map { makeLine($0, style: style, font: font, t: t) }
        let lineWidths = ctLines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }
        let contentW = ceil(CGFloat(lineWidths.max() ?? 0))
        let contentH = ceil(CGFloat(lines.count) * lineHeight)
        let W = max(2, contentW + padX * 2), H = max(2, contentH + padY * 2)

        guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))

        if let box = style.boxColor {
            let rect = CGRect(x: 0, y: 0, width: W, height: H)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(H * 0.28, fontSize * 0.6),
                               cornerHeight: min(H * 0.28, fontSize * 0.6), transform: nil))
            ctx.setFillColor(box.cgColor)
            ctx.fillPath()
        }

        for (row, line) in ctLines.enumerated() {
            let lineW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let baselineY = H - padY - ascent - CGFloat(row) * lineHeight
            ctx.textPosition = CGPoint(x: (W - lineW) / 2, y: baselineY)
            CTLineDraw(line, ctx)
        }
        guard let cg = ctx.makeImage() else { return nil }
        return (cg, CGSize(width: W, height: H))
    }

    /// An attributed line with per-word color (active / past / future) and optional outline.
    private func makeLine(_ words: [CaptionWord], style: CaptionStyle, font: CTFont, t: Double) -> CTLine {
        let fg = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let fnt = NSAttributedString.Key(kCTFontAttributeName as String)
        let strokeC = NSAttributedString.Key(kCTStrokeColorAttributeName as String)
        let strokeW = NSAttributedString.Key(kCTStrokeWidthAttributeName as String)

        let s = NSMutableAttributedString()
        for (i, w) in words.enumerated() {
            let text = (style.uppercase ? w.text.uppercased() : w.text) + (i < words.count - 1 ? " " : "")
            let color = wordColor(w, style: style, t: t)
            var attrs: [NSAttributedString.Key: Any] = [fnt: font, fg: color.cgColor]
            if style.outline { attrs[strokeC] = style.outlineColor.cgColor; attrs[strokeW] = -8.0 }
            s.append(NSAttributedString(string: text, attributes: attrs))
        }
        return CTLineCreateWithAttributedString(s)
    }

    private func wordColor(_ w: CaptionWord, style: CaptionStyle, t: Double) -> NSColor {
        guard style.animated else { return style.baseColor }
        if w.start <= t && t < w.end { return style.activeColor }   // active
        if w.end <= t { return style.baseColor }                    // already spoken
        return style.futureColor                                    // upcoming
    }
}
