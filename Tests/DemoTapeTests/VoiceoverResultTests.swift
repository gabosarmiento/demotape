import XCTest
import AVFoundation
@testable import DemoTape

/// Commit 1 coverage: the voiceover assembly keeps the ElevenLabs narration audio in the
/// output, preserves a durable narration file beside the video, and supports explicit cleanup.
/// All fixtures are generated locally — no network, no API key.
final class VoiceoverResultTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-vo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Tests

    func testVoiceoverVideoContainsNarrationAudio() throws {
        let video = try makeSilentVideo(name: "clip.styled.mp4", seconds: 2)
        let narration = try makeSilenceAudio(name: "eleven.caf", seconds: 2)

        let result = try Voiceover().assembleVoiceover(video: video, narrationAudio: narration)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.videoURL.path))
        let asset = AVAsset(url: result.videoURL)
        XCTAssertFalse(asset.tracks(withMediaType: .video).isEmpty, "output must keep the video track")
        XCTAssertFalse(asset.tracks(withMediaType: .audio).isEmpty,
                       "the voiceover video must contain the (ElevenLabs) narration audio track")
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), 2, accuracy: 0.6)
    }

    func testNarrationRemainsAvailableAfterGeneration() throws {
        let video = try makeSilentVideo(name: "clip.styled.mp4", seconds: 2)
        let narration = try makeSilenceAudio(name: "eleven.caf", seconds: 2)

        let result = try Voiceover().assembleVoiceover(video: video, narrationAudio: narration)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.narrationAudioURL.path),
                      "narration audio must remain on disk after generation")
        XCTAssertTrue(result.narrationAudioURL.lastPathComponent.hasSuffix(".voiceover.narration.m4a"),
                      "narration uses the documented …voiceover.narration.m4a naming")
        XCTAssertEqual(result.narrationAudioURL.deletingLastPathComponent().path,
                       result.videoURL.deletingLastPathComponent().path,
                       "narration must live beside the voiceover output, not only in tmp")
        XCTAssertFalse(AVAsset(url: result.narrationAudioURL).tracks(withMediaType: .audio).isEmpty,
                       "durable narration file must be a valid audio file")
    }

    func testCleanupNarrationRemovesNarrationButKeepsVideo() throws {
        let video = try makeSilentVideo(name: "clip.styled.mp4", seconds: 1)
        let narration = try makeSilenceAudio(name: "eleven.caf", seconds: 1)

        let result = try Voiceover().assembleVoiceover(video: video, narrationAudio: narration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.narrationAudioURL.path))

        result.cleanupNarration()   // explicit, later cleanup

        XCTAssertFalse(FileManager.default.fileExists(atPath: result.narrationAudioURL.path),
                       "cleanupNarration must remove the durable narration file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.videoURL.path),
                      "cleanup must not touch the voiceover video")
    }

    func testDerivedPathsStripStyledSuffix() {
        let src = URL(fileURLWithPath: "/tmp/x/My Demo.styled.mp4")
        XCTAssertEqual(Voiceover.outputURL(for: src).lastPathComponent, "My Demo.voiceover.mp4")
        XCTAssertEqual(Voiceover.narrationURL(for: src).lastPathComponent, "My Demo.voiceover.narration.m4a")
    }

    // MARK: - Fixtures

    private func makeSilentVideo(name: String, seconds: Int) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        let w = 160, h = 120, fps = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let total = fps * seconds
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buffer = pb else { throw NSError(domain: "test", code: 1) }
            input.append(sampleBuffer(from: buffer,
                                      at: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        XCTAssertEqual(writer.status, .completed, "fixture video failed: \(String(describing: writer.error))")
        return url
    }

    /// Wrap a pixel buffer in a timed CMSampleBuffer for appending without an adaptor pool.
    private func sampleBuffer(from pixelBuffer: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer {
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: time.timescale),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                           dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                           formatDescription: formatDesc!, sampleTiming: &timing,
                                           sampleBufferOut: &sb)
        return sb!
    }

    private func makeSilenceAudio(name: String, seconds: Int) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44100 * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "test", code: 2)
        }
        buffer.frameLength = frames   // zeroed = silence
        try file.write(from: buffer)
        return url
    }
}
