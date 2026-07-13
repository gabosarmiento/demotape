import XCTest
import AVFoundation
import CoreImage
@testable import DemoTape

/// Compositor tests with locally generated fixtures — no network, no API key.
final class AvatarCompositorTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-avatar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: workDir) }

    func testChromaKeyMakesGreenTransparentAndKeepsRed() {
        let remover = ChromaKeyRemover(hex: "#00B140")
        let green = CIImage(color: CIColor(red: 0, green: 0.69, blue: 0.25)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let red = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertLessThan(alpha(of: remover.removeBackground(green)), 0.2, "green should be keyed out")
        XCTAssertGreaterThan(alpha(of: remover.removeBackground(red)), 0.8, "non-green should be retained")
    }

    func testCompositePreservesScreenAudioAndDuration() throws {
        let screen = try makeVideo(name: "screen.voiceover.mp4", seconds: 2, green: false, withAudio: true)
        let avatar = try makeVideo(name: "avatar.mp4", seconds: 2, green: true, withAudio: false)
        let out = workDir.appendingPathComponent("screen.avatar.mp4")

        let compositor = AvatarCompositor(remover: ChromaKeyRemover())
        try compositor.compose(screen: screen, avatar: avatar, to: out, layout: .init())

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let asset = AVAsset(url: out)
        XCTAssertFalse(asset.tracks(withMediaType: .video).isEmpty)
        XCTAssertFalse(asset.tracks(withMediaType: .audio).isEmpty,
                       "the ElevenLabs narration (screen audio) must be preserved")
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), 2, accuracy: 0.6)
        XCTAssertEqual(asset.tracks(withMediaType: .video).first?.naturalSize.width, 320,
                       "original resolution is preserved")
    }

    func testCompositeHoldsWhenAvatarShorterThanScreen() throws {
        let screen = try makeVideo(name: "screen.voiceover.mp4", seconds: 3, green: false, withAudio: true)
        let avatar = try makeVideo(name: "avatar.mp4", seconds: 1, green: true, withAudio: false)
        let out = workDir.appendingPathComponent("held.avatar.mp4")
        try AvatarCompositor(remover: ChromaKeyRemover()).compose(screen: screen, avatar: avatar, to: out, layout: .init())
        // Output clamped to the (longer) screen duration; last avatar frame is held.
        XCTAssertEqual(CMTimeGetSeconds(AVAsset(url: out).duration), 3, accuracy: 0.6)
    }

    // MARK: - Helpers

    private func alpha(of image: CIImage) -> CGFloat {
        let ctx = CIContext()
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return CGFloat(px[3]) / 255.0
    }

    private func makeVideo(name: String, seconds: Int, green: Bool, withAudio: Bool) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        let w = 320, h = 240, fps = 12
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(vIn)

        var audioIn: AVAssetWriterInput?
        if withAudio {
            let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            ain.expectsMediaDataInRealTime = false
            writer.add(ain); audioIn = ain
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Video frames (solid green or gray).
        let ctx = CIContext()
        let color = green ? CIColor(red: 0, green: 0.69, blue: 0.25) : CIColor(red: 0.5, green: 0.5, blue: 0.5)
        let img = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let total = fps * seconds
        for i in 0..<total {
            while !vIn.isReadyForMoreMediaData { usleep(1000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            ctx.render(img, to: pb!, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        vIn.markAsFinished()

        if let ain = audioIn {
            appendSilence(to: ain, seconds: Double(seconds))
            ain.markAsFinished()
        }
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        XCTAssertEqual(writer.status, .completed, "fixture failed: \(String(describing: writer.error))")
        return url
    }

    private func appendSilence(to input: AVAssetWriterInput, seconds: Double) {
        let sampleRate = 44100.0
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                      channels: 1, interleaved: true) else { return }
        let framesPerChunk = AVAudioFrameCount(sampleRate * 0.5)
        var pts = CMTime.zero
        var remaining = seconds
        while remaining > 0 {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: framesPerChunk) else { break }
            buf.frameLength = framesPerChunk
            if let sb = sampleBuffer(from: buf, at: pts) { input.append(sb) }
            pts = CMTimeAdd(pts, CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(sampleRate)))
            remaining -= 0.5
        }
    }

    private func sampleBuffer(from pcm: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        let fmtDesc = pcm.format.formatDescription
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmtDesc,
            sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: [CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100),
                                                   presentationTimeStamp: time, decodeTimeStamp: .invalid)],
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard status == noErr, let sb = sb else { return nil }
        CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.mutableAudioBufferList)
        return sb
    }
}
