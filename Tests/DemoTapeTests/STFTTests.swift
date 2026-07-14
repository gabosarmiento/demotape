import XCTest
@testable import DemoTape

final class STFTTests: XCTestCase {

    private func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    private func signal(_ n: Int) -> [Float] {
        let w = 2.0 * Double.pi * 440.0 / 48000.0
        return (0..<n).map { 0.5 * Float(sin(w * Double($0))) + 0.1 * Float(sin(3 * w * Double($0))) }
    }

    func testIdentityRoundTripPreservesSignal() {
        let x = signal(24000)                 // 0.5 s @ 48 kHz
        let stft = STFT(fftSize: 1024, hop: 256)
        let y = stft.process(x) { _, _, _ in }   // no-op transform → should reconstruct the input
        XCTAssertEqual(y.count, x.count)

        // Compare away from the very edges (window taper) — interior should match closely.
        let lo = 2048, hi = x.count - 2048
        var err: Float = 0, ref: Float = 0
        for i in lo..<hi { err += (y[i] - x[i]) * (y[i] - x[i]); ref += x[i] * x[i] }
        let relative = (err / max(ref, 1e-9)).squareRoot()
        XCTAssertLessThan(relative, 0.02, "round-trip should reconstruct the interior within ~2%")
    }

    func testZeroGainSilencesOutput() {
        let x = signal(12000)
        let stft = STFT(fftSize: 1024, hop: 256)
        let y = stft.process(x) { _, real, imag in
            for k in 0..<real.count { real[k] = 0; imag[k] = 0 }
        }
        XCTAssertLessThan(rms(y), rms(x) * 0.05, "zeroing the spectrum should silence the output")
    }

    func testShortInputReturnedUnchanged() {
        let x = [Float](repeating: 0.2, count: 100)   // < fftSize
        let y = STFT(fftSize: 1024, hop: 256).process(x) { _, _, _ in }
        XCTAssertEqual(y, x)
    }
}
