import Foundation
import Accelerate

/// A small, reusable short-time Fourier transform with weighted overlap-add reconstruction
/// (Hann analysis + synthesis, 75% overlap by default). It streams frame-by-frame — a `transform`
/// closure gets each frame's magnitude spectrum and may modify the complex spectrum in place —
/// so memory stays flat regardless of clip length. The forward/inverse round-trip is
/// self-calibrated to be an identity when `transform` leaves the spectrum untouched.
///
/// Used by the Core ML speech enhancer (magnitude → learned gain → resynthesis). The classic
/// `NoiseReducer` keeps its own copy for now; this is the shared, unit-tested engine going forward.
struct STFT {
    let n: Int          // FFT size (power of two)
    let hop: Int        // hop size (n/4 = 75% overlap is typical)

    init(fftSize: Int = 1024, hop: Int = 256) {
        self.n = fftSize
        self.hop = hop
    }

    /// Runs the STFT over `input`, calling `transform(magnitude, &real, &imag)` per frame, and
    /// returns the overlap-added reconstruction (same length as `input`). Returns `input`
    /// unchanged if it's shorter than one frame or the FFT setup fails.
    func process(_ input: [Float],
                 _ transform: (_ magnitude: [Float], _ real: inout [Float], _ imag: inout [Float]) -> Void) -> [Float] {
        guard input.count >= n else { return input }
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return input }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // Self-calibrate the forward→inverse constant so reconstruction is exact regardless of
        // vDSP's scaling conventions.
        let scale = 1.0 / roundTripConstant(setup: setup, log2n: log2n, window: window, half: half)

        // Pad a full window each side so every real sample gets full overlap coverage, then trim.
        let pad = n
        var signal = [Float](repeating: 0, count: pad) + input + [Float](repeating: 0, count: pad)
        let frameCount = max(1, (signal.count - n + hop - 1) / hop + 1)
        let paddedLen = (frameCount - 1) * hop + n
        if signal.count < paddedLen {
            signal.append(contentsOf: [Float](repeating: 0, count: paddedLen - signal.count))
        }

        var output = [Float](repeating: 0, count: paddedLen)
        var normalizer = [Float](repeating: 0, count: paddedLen)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)
        var mag = [Float](repeating: 0, count: half)
        var time = [Float](repeating: 0, count: n)

        for f in 0..<frameCount {
            let start = f * hop
            for i in 0..<n { windowed[i] = signal[start + i] * window[i] }

            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }

            transform(mag, &realp, &imagp)

            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    time.withUnsafeMutableBufferPointer { tp in
                        tp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            var sc = scale
            vDSP_vsmul(time, 1, &sc, &time, 1, vDSP_Length(n))
            for i in 0..<n {
                let w = window[i]
                output[start + i] += time[i] * w
                normalizer[start + i] += w * w
            }
        }
        for i in 0..<paddedLen { output[i] = normalizer[i] > 1e-4 ? output[i] / normalizer[i] : 0 }
        return Array(output[pad ..< pad + input.count])
    }

    private func roundTripConstant(setup: FFTSetup, log2n: vDSP_Length, window: [Float], half: Int) -> Float {
        let n = self.n
        var rp = [Float](repeating: 0, count: half)
        var ip = [Float](repeating: 0, count: half)
        var out = [Float](repeating: 0, count: n)
        rp.withUnsafeMutableBufferPointer { rpp in
            ip.withUnsafeMutableBufferPointer { ipp in
                var split = DSPSplitComplex(realp: rpp.baseAddress!, imagp: ipp.baseAddress!)
                window.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(half))
                    }
                }
            }
        }
        var num: Float = 0, den: Float = 0
        for i in 0..<n { num += out[i] * window[i]; den += window[i] * window[i] }
        return den > 0 ? num / den : Float(2 * n)
    }
}
