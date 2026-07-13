import XCTest
@testable import DemoTape

final class NoiseReducerTests: XCTestCase {

    private let sampleRate = 48000.0

    private func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        let sumSq = x.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSq / Float(x.count)).squareRoot()
    }

    /// First half: steady background noise only. Second half: a 1 kHz tone over the same noise —
    /// a fair proxy for "silence then speech", which is what a spectral gate is designed for.
    private func noiseThenTone(seconds: Double, toneAmp: Float, noiseAmp: Float) -> (mix: [Float], half: Int) {
        let n = Int(seconds * sampleRate)
        let half = n / 2
        var rng = SeededRNG(seed: 42)
        var mix = [Float](repeating: 0, count: n)
        let w = 2.0 * Double.pi * 1000.0 / sampleRate
        for i in 0..<n {
            let r = (Float(rng.next() % 20001) / 10000.0) - 1.0    // -1…1 white noise
            var s = noiseAmp * r
            if i >= half { s += toneAmp * Float(sin(w * Double(i))) }
            mix[i] = s
        }
        return (mix, half)
    }

    func testRemovesNoiseInSilentRegionAndPreservesLength() {
        let (mix, half) = noiseThenTone(seconds: 1.0, toneAmp: 0.35, noiseAmp: 0.12)
        let cleaned = NoiseReducer.denoiseMono(mix, strength: 0.9)

        XCTAssertEqual(cleaned.count, mix.count, "length preserved")

        let noiseBefore = rms(mix[0..<half])
        let noiseAfter = rms(cleaned[0..<half])
        // White noise is the hardest case for a spectral gate (broadband, no structure); steady
        // hum/hiss reduces much more. Even here it should come down meaningfully.
        XCTAssertLessThan(noiseAfter, noiseBefore * 0.8,
                          "background noise in the silent region should drop noticeably")
    }

    func testPreservesTheSignalBurst() {
        let (mix, half) = noiseThenTone(seconds: 1.0, toneAmp: 0.35, noiseAmp: 0.12)
        let cleaned = NoiseReducer.denoiseMono(mix, strength: 0.9)
        // The tone burst (like speech) should clearly survive.
        XCTAssertGreaterThan(rms(cleaned[half...]), 0.12, "the speech-like burst should be preserved")
    }

    func testStrengthZeroIsPassthrough() {
        let (mix, _) = noiseThenTone(seconds: 0.5, toneAmp: 0.3, noiseAmp: 0.1)
        XCTAssertEqual(NoiseReducer.denoiseMono(mix, strength: 0.0), mix, "strength 0 must not alter the signal")
    }

    func testShortInputIsReturnedUnchanged() {
        let short = [Float](repeating: 0.1, count: 100)   // < fftSize
        XCTAssertEqual(NoiseReducer.denoiseMono(short, strength: 0.9), short)
    }
}
