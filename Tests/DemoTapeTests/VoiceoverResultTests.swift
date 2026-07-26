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

// MARK: - Variants and fit
//
// A second language must be an additional file, not a replacement, and its lines have to fit the
// moments they describe — translated narration runs longer than the English it came from, and the mux
// never overlaps clips, so one long line pushes every later line out of sync.

final class VoiceoverVariantTests: XCTestCase {

    func testTagMakesAVariantFileInsteadOfReplacingTheOriginal() {
        let styled = URL(fileURLWithPath: "/tmp/Demo 1.styled.mp4")
        XCTAssertEqual(Voiceover.outputURL(for: styled).lastPathComponent, "Demo 1.voiceover.mp4")
        XCTAssertEqual(Voiceover.outputURL(for: styled, tag: "es").lastPathComponent, "Demo 1.voiceover.es.mp4")
        XCTAssertEqual(Voiceover.outputURL(for: styled, tag: "").lastPathComponent, "Demo 1.voiceover.mp4")
    }

    func testTaggingAnAlreadyVoicedFileDoesNotStackSuffixes() {
        let voiced = URL(fileURLWithPath: "/tmp/Demo 1.voiceover.mp4")
        XCTAssertEqual(Voiceover.outputURL(for: voiced, tag: "fr").lastPathComponent, "Demo 1.voiceover.fr.mp4")
    }

    func testOverrunIsMeasuredAgainstTheNextLine() {
        // Second line is 8s long but only has 5s of room before the third starts.
        let over = Voiceover.overruns(offsets: [0, 10, 15], durations: [6, 8, 3], videoDuration: 30)
        XCTAssertEqual(over[0], 0, accuracy: 0.001)
        XCTAssertEqual(over[1], 3, accuracy: 0.001)
        XCTAssertEqual(over[2], 0, accuracy: 0.001)
    }

    func testLastLineIsMeasuredAgainstTheVideo() {
        XCTAssertEqual(Voiceover.overruns(offsets: [0], durations: [12], videoDuration: 10)[0], 2, accuracy: 0.001)
        XCTAssertEqual(Voiceover.overruns(offsets: [0], durations: [8], videoDuration: 10)[0], 0, accuracy: 0.001)
        // No video duration given: the tail can't be judged, so it isn't.
        XCTAssertEqual(Voiceover.overruns(offsets: [0], durations: [99])[0], 0, accuracy: 0.001)
    }

    func testMismatchedInputsReportNothingRatherThanGuess() {
        XCTAssertTrue(Voiceover.overruns(offsets: [0, 5], durations: [3]).isEmpty)
    }
}

// MARK: - Timed scripts
//
// The editable form of a scene-synced narration: `[12.4] the line`. It has to survive a round trip
// through a text editor, because translating a demo means editing exactly this.

final class VoiceoverTimedScriptTests: XCTestCase {

    func testParsesOffsetsAndText() {
        let lines = Voiceover.parseTimedScript("[0.0] First line\n\n[11.6] Second line")
        XCTAssertEqual(lines, [Voiceover.TimedLine(at: 0, say: "First line"),
                               Voiceover.TimedLine(at: 11.6, say: "Second line")])
    }

    func testUntimedLinesContinueThePreviousOne() {
        // A wrapped paragraph must not become a new scene at time zero.
        let lines = Voiceover.parseTimedScript("[3.0] The line keeps\ngoing over two rows")
        XCTAssertEqual(lines, [Voiceover.TimedLine(at: 3, say: "The line keeps going over two rows")])
    }

    func testPlainProseIsNotATimedScript() {
        XCTAssertTrue(Voiceover.parseTimedScript("Just a paragraph of narration.").isEmpty)
    }

    func testRoundTrip() {
        let lines = [Voiceover.TimedLine(at: 0, say: "Uno"), Voiceover.TimedLine(at: 7.2, say: "Dos")]
        XCTAssertEqual(Voiceover.parseTimedScript(Voiceover.formatTimedScript(lines)), lines)
    }

    func testEmptyLinesAreDropped() {
        XCTAssertEqual(Voiceover.parseTimedScript("[1.0] \n[2.0] Real").count, 1)
    }
}

// MARK: - Localization
//
// The picker's data, the cost shown before spending anything, and the prompt handed to a coding
// agent. All three are read by a person about to make a decision, so they have to be right.

final class NarrationLocalizationTests: XCTestCase {

    func testLanguageCodesAreUniqueAndUsableAsFileTags() {
        let codes = NarrationLocalization.languages.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        for code in codes {
            XCTAssertFalse(code.isEmpty)
            XCTAssertTrue(code.allSatisfy { $0.isLetter && $0.isLowercase }, "bad tag: \(code)")
        }
    }

    func testLookupIsCaseInsensitive() {
        XCTAssertEqual(NarrationLocalization.language(forCode: "ES")?.name, "Spanish")
        XCTAssertNil(NarrationLocalization.language(forCode: "zz"))
    }

    func testLabelShowsBothNamesUnlessTheyMatch() {
        let es = NarrationLocalization.language(forCode: "es")!
        XCTAssertEqual(NarrationLocalization.label(for: es), "Spanish (Español)")
        let en = NarrationLocalization.language(forCode: "en")!
        XCTAssertEqual(NarrationLocalization.label(for: en), "English")
    }

    func testCostCountsEveryLine() {
        let lines = [Voiceover.TimedLine(at: 0, say: "abcde"), Voiceover.TimedLine(at: 1, say: "xyz")]
        XCTAssertEqual(NarrationLocalization.characterCount(of: lines), 8)
    }

    func testCostSummarySaysWhenARunWontFitTheBalance() {
        XCTAssertTrue(NarrationLocalization.costSummary(characters: 3000, remaining: 1000)
                        .contains("more than"))
        XCTAssertTrue(NarrationLocalization.costSummary(characters: 300, remaining: 1000)
                        .contains("700"))
        // Unknown balance: state the cost, claim nothing about what's left.
        let unknown = NarrationLocalization.costSummary(characters: 300, remaining: nil)
        XCTAssertFalse(unknown.contains("credits now"))
    }

    func testAgentPromptCarriesThePathsCommandAndFitRule() {
        let fr = NarrationLocalization.language(forCode: "fr")!
        let p = NarrationLocalization.agentPrompt(recordingDir: "/Movies/Demo 1", language: fr)
        XCTAssertTrue(p.contains("/Movies/Demo 1"))
        XCTAssertTrue(p.contains("timeline.json"))
        XCTAssertTrue(p.contains("lines-fr.json"))
        XCTAssertTrue(p.contains("narrate"))
        XCTAssertTrue(p.contains("drift"))            // the loop, not just the command
        XCTAssertTrue(p.contains("voiceover.fr.mp4"))
    }
}
