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
        let cleaned = channels.map {
            Self.denoiseMono($0, strength: strength, fftSize: fftSize, hop: hop, sampleRate: sampleRate)
        }

        let tempAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-nr-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempAudio) }
        try AudioTrackIO.writeAAC(channels: cleaned, sampleRate: sampleRate, to: tempAudio)
        try AudioTrackIO.mux(video: video, audio: tempAudio, to: out)
    }

    // MARK: - Core (pure, testable)

    /// Denoise a single mono channel. Two passes: estimate a per-bin noise floor, then apply a
    /// decision-directed Wiener gain (Ephraim–Malah — smooth across frames, so it suppresses hard
    /// without "musical noise"), a spectral high-pass that kills sub-85 Hz fan/AC rumble, and a
    /// gentle duck of speech-absent frames. Blended by `strength`, reconstructed with WOLA.
    static func denoiseMono(_ input: [Float], strength: Double, fftSize n: Int = 1024, hop: Int = 256,
                            sampleRate: Double = 48000) -> [Float] {
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

        // Pre-filter: a 4th-order (cascaded biquad) high-pass at 85 Hz removes low-frequency
        // fan/AC rumble cleanly — far sharper than the coarse FFT bins can, and below the voice.
        var hp1 = Biquad.highPass(sampleRate: sampleRate, freq: 85, q: 0.707)
        var hp2 = Biquad.highPass(sampleRate: sampleRate, freq: 85, q: 0.707)
        var pre = input
        for i in 0..<pre.count { pre[i] = hp2.process(hp1.process(input[i])) }

        // Zero-pad by a full window on each side so every real sample is covered by full
        // window overlap (Hann is ~0 at frame edges → avoids divide-by-tiny spikes), then trim.
        let pad = n
        var signal = [Float](repeating: 0, count: pad) + pre + [Float](repeating: 0, count: pad)
        let frameCount = max(1, (signal.count - n + hop - 1) / hop + 1)
        let paddedLen = (frameCount - 1) * hop + n
        if signal.count < paddedLen { signal.append(contentsOf: [Float](repeating: 0, count: paddedLen - signal.count)) }

        // Streaming, memory-light denoise. Two FFT passes are *recomputed* (not stored), so RAM
        // stays flat regardless of clip length — the old code kept every frame's spectrum in
        // memory (~700 MB for a 10-minute clip), which is what spun the fan up on long renders.
        // Pass A estimates the steady per-bin noise floor with a compact per-bin magnitude
        // histogram (a low percentile = the fan/room floor). Pass B applies a decision-directed
        // Wiener gain (band-smoothed) with a pause duck, reconstructed by weighted overlap-add.
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)
        var mag = [Float](repeating: 0, count: half)

        // Forward FFT of frame `f` → fills realp / imagp / mag (reused buffers, zero per-frame allocs).
        func forwardFFT(_ f: Int) {
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
        }

        // Pass A: per-bin log-magnitude histogram → 15th-percentile noise floor. ~128 KB total.
        let nb = 64
        let histLo: Float = -20, histStep: Float = 0.5   // covers 2^-20 … 2^12 magnitude
        var hist = [Int32](repeating: 0, count: half * nb)
        for f in 0..<frameCount {
            forwardFFT(f)
            for k in 0..<half {
                let m = mag[k]
                let b = m > 0 ? Int((log2f(m) - histLo) / histStep) : 0
                hist[k * nb + min(max(b, 0), nb - 1)] += 1
            }
        }
        var noise = [Float](repeating: 0, count: half)
        let target = max(1, Int(Double(frameCount) * 0.15))
        for k in 0..<half {
            var cum = 0, chosen = 0
            for b in 0..<nb { cum += Int(hist[k * nb + b]); if cum >= target { chosen = b; break } }
            noise[k] = exp2f(histLo + (Float(chosen) + 0.5) * histStep)
        }

        // Pass B: decision-directed Wiener gain, band-smoothed, pause-ducked; IFFT + WOLA.
        var output = [Float](repeating: 0, count: paddedLen)
        var normalizer = [Float](repeating: 0, count: paddedLen)
        var time = [Float](repeating: 0, count: n)
        var gain = [Float](repeating: 1, count: half)
        var gainSm = [Float](repeating: 1, count: half)

        let alphaDD: Float = 0.98                       // a-priori-SNR smoothing (kills musical noise)
        let noiseOver: Float = 2.4                      // over-estimate the noise → suppress harder
        let gMin = 0.02 + 0.02 * (1 - s)                // deeper spectral floor (stronger attenuation)
        let pauseFloor: Float = 0.20                    // duck speech-absent frames harder
        var gPrev = [Float](repeating: 1, count: half)
        var gammaPrev = [Float](repeating: 1, count: half)

        for f in 0..<frameCount {
            forwardFFT(f)

            // Frame-level SNR → smooth speech-presence probability (for the pause duck).
            var sigPow: Float = 0, noiPow: Float = 0
            for k in 0..<half {
                let np = max(noise[k] * noiseOver, 1e-9)
                sigPow += mag[k] * mag[k]; noiPow += np * np
            }
            let frameSNRdB = 10 * log10f(max(noiPow > 0 ? sigPow / noiPow : 1, 1e-9))
            let speechProb = min(1, max(0, frameSNRdB / 12))          // ramp 0…12 dB
            let pauseGain = pauseFloor + (1 - pauseFloor) * speechProb

            for k in 0..<half {
                let np = max(noise[k] * noiseOver, 1e-9)
                let npp = np * np
                let yp = max(mag[k] * mag[k], 1e-12)
                let gamma = yp / npp                                 // a-posteriori SNR
                let xi = alphaDD * (gPrev[k] * gPrev[k] * gammaPrev[k])
                       + (1 - alphaDD) * max(gamma - 1, 0)           // decision-directed a-priori SNR
                var G = xi / (xi + 1)                                // Wiener gain
                G = max(gMin, min(1, G))
                gammaPrev[k] = gamma; gPrev[k] = G                   // recurse on the clean gain
                gain[k] = G
            }
            // Smooth gains across neighbouring bins (5-tap, band-like). Wider smoothing keeps the
            // more aggressive suppression above from turning into musical noise under speech.
            for k in 0..<half {
                let a = gain[max(0, k - 2)], b = gain[max(0, k - 1)], c = gain[k]
                let d = gain[min(half - 1, k + 1)], e = gain[min(half - 1, k + 2)]
                gainSm[k] = 0.1 * a + 0.2 * b + 0.4 * c + 0.2 * d + 0.1 * e
            }

            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    for k in 0..<half {
                        let g = (1 - s) + s * gainSm[k] * pauseGain  // duck + strength blend
                        rp[k] *= g; ip[k] *= g
                    }
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

