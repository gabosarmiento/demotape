import XCTest
@testable import DemoTape

final class VoiceEnhancerTests: XCTestCase {

    private let sampleRate = 48000.0

    private func peak(_ x: [Float]) -> Float { x.reduce(Float(0)) { max($0, abs($1)) } }

    /// A signal with a long loud segment then a long quiet segment (same 300 Hz tone). Segments
    /// are 1 s so the compressor's envelope settles; we measure the steady tail of each (last
    /// 0.3 s), avoiding the release-lag transition between them.
    private func loudThenQuiet() -> (mix: [Float], loud: Range<Int>, quiet: Range<Int>) {
        let seg = Int(1.0 * sampleRate)
        let tail = Int(0.3 * sampleRate)
        var x = [Float](repeating: 0, count: seg * 2)
        let w = 2.0 * Double.pi * 300.0 / sampleRate
        for i in 0..<seg { x[i] = 0.8 * Float(sin(w * Double(i))) }                 // loud
        for i in 0..<seg { x[seg + i] = 0.1 * Float(sin(w * Double(seg + i))) }     // quiet
        return (x, (seg - tail)..<seg, (seg * 2 - tail)..<(seg * 2))                // steady tails
    }

    func testNeverClips() {
        let (mix, _, _) = loudThenQuiet()
        let out = VoiceEnhancer.processMono(mix, sampleRate: sampleRate)
        XCTAssertLessThanOrEqual(peak(out), 1.0, "output must not clip")
        XCTAssertEqual(out.count, mix.count, "length preserved")
    }

    func testReducesDynamicRange() {
        let (mix, loud, quiet) = loudThenQuiet()
        let out = VoiceEnhancer.processMono(mix, sampleRate: sampleRate)

        let loudBeforeQuietRatio = peak(Array(mix[loud])) / max(peak(Array(mix[quiet])), 1e-6)
        let loudAfterQuietRatio = peak(Array(out[loud])) / max(peak(Array(out[quiet])), 1e-6)
        XCTAssertLessThan(loudAfterQuietRatio, loudBeforeQuietRatio,
                          "the compressor should narrow the loud/quiet gap")
    }

    func testProducesOutputForNormalSpeechLevel() {
        // A moderate tone should come out at a healthy, normalized level (not silent).
        let n = Int(0.5 * sampleRate)
        let w = 2.0 * Double.pi * 300.0 / sampleRate
        let x = (0..<n).map { 0.2 * Float(sin(w * Double($0))) }
        let out = VoiceEnhancer.processMono(x, sampleRate: sampleRate)
        XCTAssertGreaterThan(peak(out), 0.3, "normalization should bring a quiet-ish tone up to a healthy level")
    }
}
