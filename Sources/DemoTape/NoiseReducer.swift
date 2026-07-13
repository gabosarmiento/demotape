import Foundation
import AVFoundation
import Accelerate

/// On-device, dependency-free noise suppression using an STFT spectral gate (Accelerate/vDSP).
///
/// It learns a per-frequency noise fingerprint from the quietest parts of the clip, then
/// attenuates each frequency bin proportionally to how noise-like it is. A `strength` of 0
/// leaves audio untouched; 1 applies maximum suppression. This is not a deep-learning denoiser
/// (no DeepFilterNet-style model), but it removes steady background noise — fans, hum, hiss,
/// room tone — very effectively for narration, entirely offline.
final class NoiseReducer {

    private let fftSize = 1024
    private let hop = 256               // 75% overlap (WOLA with Hann analysis+synthesis)

    // MARK: - Video pipeline

    /// Cleans the audio of `video` and writes a copy at `out` (video copied without re-encoding,
    /// audio replaced with the denoised track). Throws if there's nothing to clean.
    func reduce(video: URL, strength: Double, to out: URL) throws {
        let (channels, sampleRate) = try AudioTrackIO.readChannels(from: AVAsset(url: video))
        let cleaned = channels.map { Self.denoiseMono($0, strength: strength, fftSize: fftSize, hop: hop) }

        let tempAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-nr-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempAudio) }
        try AudioTrackIO.writeAAC(channels: cleaned, sampleRate: sampleRate, to: tempAudio)
        try AudioTrackIO.mux(video: video, audio: tempAudio, to: out)
    }

    // MARK: - Core (pure, testable)

    /// Denoise a single mono channel. Two passes: estimate a per-bin noise floor, then apply an
    /// Wiener-style gain blended by `strength`, reconstructed with weighted overlap-add.
    static func denoiseMono(_ input: [Float], strength: Double, fftSize n: Int = 1024, hop: Int = 256) -> [Float] {
        let s = Float(min(max(strength, 0), 1))
        guard s > 0, input.count >= n else { return input }
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return input }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // Self-calibrate the FFT round-trip constant so reconstruction is exact (identity),
        // independent of vDSP's forward/inverse scaling conventions.
        let roundTrip: Float = {
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
        }()
        let scale = 1.0 / roundTrip

        // Zero-pad by a full window on each side so every real sample is covered by full
        // window overlap (Hann is ~0 at frame edges → avoids divide-by-tiny spikes), then trim.
        let pad = n
        var signal = [Float](repeating: 0, count: pad) + input + [Float](repeating: 0, count: pad)
        let frameCount = max(1, (signal.count - n + hop - 1) / hop + 1)
        let paddedLen = (frameCount - 1) * hop + n
        if signal.count < paddedLen { signal.append(contentsOf: [Float](repeating: 0, count: paddedLen - signal.count)) }

        // Pass 1: forward FFT per frame, keep spectra + magnitudes.
        var realFrames = [[Float]](repeating: [Float](repeating: 0, count: half), count: frameCount)
        var imagFrames = [[Float]](repeating: [Float](repeating: 0, count: half), count: frameCount)
        var mags = [[Float]](repeating: [Float](repeating: 0, count: half), count: frameCount)

        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)

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
                    var m = [Float](repeating: 0, count: half)
                    vDSP_zvabs(&split, 1, &m, 1, vDSP_Length(half))
                    realFrames[f] = Array(rp)
                    imagFrames[f] = Array(ip)
                    mags[f] = m
                }
            }
        }

        // Per-bin noise floor: a low percentile of magnitude across frames (steady noise).
        var noise = [Float](repeating: 0, count: half)
        let pIndex = max(0, Int(Double(frameCount) * 0.15))
        for k in 0..<half {
            var col = [Float](repeating: 0, count: frameCount)
            for f in 0..<frameCount { col[f] = mags[f][k] }
            col.sort()
            noise[k] = col[min(pIndex, frameCount - 1)]
        }

        // Pass 2: apply gain, inverse FFT, weighted overlap-add.
        var output = [Float](repeating: 0, count: paddedLen)
        var normalizer = [Float](repeating: 0, count: paddedLen)
        // Over-subtraction grows with strength; spectral floor shrinks with strength.
        let beta = 1.0 + 2.0 * s                    // 1…3
        let floorGain = 0.20 * (1 - s) + 0.02       // musical-noise floor
        var time = [Float](repeating: 0, count: n)

        for f in 0..<frameCount {
            var rp = realFrames[f]
            var ip = imagFrames[f]
            let m = mags[f]
            for k in 0..<half {
                let mk = max(m[k], 1e-9)
                let ratio = noise[k] / mk
                var gain = 1 - beta * ratio * ratio  // power spectral subtraction
                gain = max(floorGain, min(1, gain))
                let g = (1 - s) + s * gain           // strength blend
                rp[k] *= g
                ip[k] *= g
            }
            rp.withUnsafeMutableBufferPointer { rpp in
                ip.withUnsafeMutableBufferPointer { ipp in
                    var split = DSPSplitComplex(realp: rpp.baseAddress!, imagp: ipp.baseAddress!)
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
            let start = f * hop
            for i in 0..<n {
                let w = window[i]
                output[start + i] += time[i] * w      // synthesis window (WOLA)
                normalizer[start + i] += w * w
            }
        }
        for i in 0..<paddedLen { output[i] = normalizer[i] > 1e-4 ? output[i] / normalizer[i] : 0 }
        // Trim the front/back padding to recover the original length.
        return Array(output[pad ..< pad + input.count])
    }
}

