import Foundation
import AVFoundation

/// "Studio voice" enhancement — makes laptop/USB-mic narration sound closer to a warm studio
/// condenser. A tasteful fixed chain, applied offline on-device (no dependencies):
///   1. High-pass (~85 Hz) to remove rumble/handling.
///   2. Gentle low-shelf warmth + presence lift (~5 kHz) for clarity.
///   3. Compressor to even out loud/quiet words (the biggest "pro mic" effect).
///   4. Normalize to a consistent target with a soft ceiling so it never clips.
final class VoiceEnhancer {

    /// Enhances the audio of `video`, writing a copy at `out` (video copied without re-encoding).
    func enhance(video: URL, to out: URL) throws {
        let (channels, sampleRate) = try AudioTrackIO.readChannels(from: AVAsset(url: video))
        let processed = Self.process(channels: channels, sampleRate: sampleRate)
        let tempAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-ve-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempAudio) }
        try AudioTrackIO.writeAAC(channels: processed, sampleRate: sampleRate, to: tempAudio)
        try AudioTrackIO.mux(video: video, audio: tempAudio, to: out)
    }

    // MARK: - Core (pure, testable)

    /// Process all channels with the fixed chain, then jointly normalize so stereo balance and
    /// overall loudness stay consistent.
    static func process(channels: [[Float]], sampleRate: Double) -> [[Float]] {
        guard sampleRate > 0 else { return channels }
        var out = channels.map { processChannel($0, sampleRate: sampleRate) }

        // Joint normalize to a consistent target peak, with a capped boost so near-silent tracks
        // aren't amplified into noise. Soft-clip guarantees no hard clipping.
        let peak = out.reduce(Float(0)) { m, ch in max(m, ch.reduce(Float(0)) { max($0, abs($1)) }) }
        if peak > 0.02 {
            let target: Float = 0.9
            let gain = min(target / peak, 4.0)
            for c in 0..<out.count {
                for i in 0..<out[c].count { out[c][i] = softClip(out[c][i] * gain) }
            }
        }
        return out
    }

    static func processMono(_ input: [Float], sampleRate: Double) -> [Float] {
        process(channels: [input], sampleRate: sampleRate).first ?? input
    }

    /// EQ (high-pass + presence peak) → compressor. Level normalization happens jointly later.
    private static func processChannel(_ input: [Float], sampleRate: Double) -> [Float] {
        guard input.count > 4 else { return input }
        var hp = Biquad.highPass(sampleRate: sampleRate, freq: 85, q: 0.707)
        var presence = Biquad.peaking(sampleRate: sampleRate, freq: 5000, q: 0.9, gainDB: 3.0)
        var warmth = Biquad.lowShelf(sampleRate: sampleRate, freq: 200, gainDB: 1.5)

        var x = input
        for i in 0..<x.count {
            var s = hp.process(x[i])
            s = warmth.process(s)
            s = presence.process(s)
            x[i] = s
        }
        return compress(x, sampleRate: sampleRate)
    }

    /// Feed-forward compressor with an envelope follower. Threshold −24 dB, ratio 3:1, with
    /// makeup gain to restore level.
    private static func compress(_ input: [Float], sampleRate: Double) -> [Float] {
        let thresholdDB: Float = -24
        let ratio: Float = 3
        let attack: Float = 0.005, release: Float = 0.15
        let attackCoef = expf(-1.0 / (attack * Float(sampleRate)))
        let releaseCoef = expf(-1.0 / (release * Float(sampleRate)))
        let makeupDB = -thresholdDB * (1 - 1 / ratio) * 0.5   // partial makeup

        var env: Float = abs(input.first ?? 0)   // prime so there's no startup gain spike
        var out = [Float](repeating: 0, count: input.count)
        for i in 0..<input.count {
            let level = abs(input[i])
            if level > env { env = attackCoef * env + (1 - attackCoef) * level }
            else { env = releaseCoef * env + (1 - releaseCoef) * level }
            let envDB = 20 * log10f(max(env, 1e-9))
            var gainDB: Float = 0
            if envDB > thresholdDB { gainDB = (thresholdDB - envDB) * (1 - 1 / ratio) }  // ≤ 0
            let gain = min(powf(10, (gainDB + makeupDB) / 20), 4)   // cap boost (don't lift silence)
            out[i] = input[i] * gain
        }
        return out
    }

    /// Symmetric soft clip: linear below 0.9, tanh-bent above so output stays under 1.0 (no
    /// hard clipping), monotonic.
    private static func softClip(_ x: Float) -> Float {
        let t: Float = 0.9
        let a = abs(x)
        if a <= t { return x }
        let sign: Float = x < 0 ? -1 : 1
        return sign * (t + (1 - t) * tanhf((a - t) / (1 - t)))
    }
}

/// A minimal RBJ-cookbook biquad (Direct Form I).
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    static func highPass(sampleRate: Double, freq: Float, q: Float) -> Biquad {
        let w0 = 2 * Float.pi * freq / Float(sampleRate)
        let cs = cosf(w0), sn = sinf(w0)
        let alpha = sn / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + cs) / 2 / a0, b1: -(1 + cs) / a0, b2: (1 + cs) / 2 / a0,
                      a1: -2 * cs / a0, a2: (1 - alpha) / a0)
    }

    static func peaking(sampleRate: Double, freq: Float, q: Float, gainDB: Float) -> Biquad {
        let A = powf(10, gainDB / 40)
        let w0 = 2 * Float.pi * freq / Float(sampleRate)
        let cs = cosf(w0), sn = sinf(w0)
        let alpha = sn / (2 * q)
        let a0 = 1 + alpha / A
        return Biquad(b0: (1 + alpha * A) / a0, b1: -2 * cs / a0, b2: (1 - alpha * A) / a0,
                      a1: -2 * cs / a0, a2: (1 - alpha / A) / a0)
    }

    static func lowShelf(sampleRate: Double, freq: Float, gainDB: Float) -> Biquad {
        let A = powf(10, gainDB / 40)
        let w0 = 2 * Float.pi * freq / Float(sampleRate)
        let cs = cosf(w0), sn = sinf(w0)
        let alpha = sn / 2 * sqrtf((A + 1 / A) * (1 / 0.9 - 1) + 2)
        let sqrtA = sqrtf(A)
        let a0 = (A + 1) + (A - 1) * cs + 2 * sqrtA * alpha
        return Biquad(
            b0: A * ((A + 1) - (A - 1) * cs + 2 * sqrtA * alpha) / a0,
            b1: 2 * A * ((A - 1) - (A + 1) * cs) / a0,
            b2: A * ((A + 1) - (A - 1) * cs - 2 * sqrtA * alpha) / a0,
            a1: -2 * ((A - 1) + (A + 1) * cs) / a0,
            a2: ((A + 1) + (A - 1) * cs - 2 * sqrtA * alpha) / a0)
    }
}
