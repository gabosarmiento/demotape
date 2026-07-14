import Foundation
import AVFoundation
import CoreML

/// A speech-enhancement backend. `NoiseReducer` (classic DSP) is always available; the Core ML
/// backend below activates only when a compatible model is bundled, otherwise the caller falls
/// back to the DSP so behaviour never regresses.
protocol SpeechEnhancer {
    var isAvailable: Bool { get }
    /// Enhanced copy of one mono channel, or nil if the backend can't run (→ caller falls back).
    func enhanceMono(_ input: [Float], sampleRate: Double) -> [Float]?
}

/// On-device neural noise suppression via Core ML (Apple-native runtime). It runs an STFT, asks
/// the model for a per-frequency gain (0…1) mask per frame, applies it, and resynthesises — the
/// standard spectral-mask interface that small speech-enhancement models (RNNoise/DTLN/DeepFilterNet
/// exports) can be converted to.
///
/// ## Model contract (see scripts/DENOISER_MODEL.md)
/// Bundle a compiled model named `Denoiser.mlmodelc` (or `.mlpackage`) in Resources with:
///   • input  — a Float32 MLMultiArray of length `fftSize/2` (the frame magnitude spectrum).
///   • output — a Float32 MLMultiArray of length `fftSize/2` (per-bin gain in 0…1).
/// I/O names are auto-discovered (first name containing "mag"/"gain"/"mask", else the first I/O).
/// If no model is present, `isAvailable` is false and the app uses the DSP reducer.
final class CoreMLSpeechEnhancer: SpeechEnhancer {

    /// Resource base name for the bundled model.
    static let resourceName = "Denoiser"

    enum EnhanceError: Error { case unavailable }

    private let model: MLModel?
    private let stft: STFT
    private let magInputName: String
    private let gainOutputName: String

    init(fftSize: Int = 1024, hop: Int = 256) {
        self.stft = STFT(fftSize: fftSize, hop: hop)
        let loaded = Self.loadModel()
        self.model = loaded
        if let d = loaded?.modelDescription {
            let ins = Array(d.inputDescriptionsByName.keys)
            let outs = Array(d.outputDescriptionsByName.keys)
            self.magInputName = ins.first { $0.lowercased().contains("mag") } ?? ins.first ?? "magnitude"
            self.gainOutputName = outs.first { let l = $0.lowercased(); return l.contains("gain") || l.contains("mask") }
                ?? outs.first ?? "gain"
        } else {
            self.magInputName = "magnitude"
            self.gainOutputName = "gain"
        }
    }

    var isAvailable: Bool { model != nil }

    private static func loadModel() -> MLModel? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: resourceName, withExtension: "mlpackage") else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: cfg)
    }

    // MARK: - Enhancement

    func enhanceMono(_ input: [Float], sampleRate: Double) -> [Float]? {
        guard let model = model, input.count >= stft.n else { return nil }
        var failed = false
        let out = stft.process(input) { mag, real, imag in
            guard !failed, let gains = self.gain(from: model, magnitude: mag) else { failed = true; return }
            let count = min(gains.count, real.count)
            for k in 0..<count {
                let g = max(0, min(1, gains[k]))
                real[k] *= g
                imag[k] *= g
            }
        }
        return failed ? nil : out
    }

    /// Enhances the mic audio of `video`, writing a copy at `out` (video stream copied). Throws
    /// `EnhanceError.unavailable` if the model can't run, so callers can fall back to the DSP.
    func reduce(video: URL, to out: URL) throws {
        guard isAvailable else { throw EnhanceError.unavailable }
        let (channels, sampleRate) = try AudioTrackIO.readChannels(from: AVAsset(url: video))
        var processed: [[Float]] = []
        for ch in channels {
            guard let e = enhanceMono(ch, sampleRate: sampleRate) else { throw EnhanceError.unavailable }
            processed.append(e)
        }
        let tempAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-ml-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempAudio) }
        try AudioTrackIO.writeAAC(channels: processed, sampleRate: sampleRate, to: tempAudio)
        try AudioTrackIO.mux(video: video, audio: tempAudio, to: out)
    }

    private func gain(from model: MLModel, magnitude: [Float]) -> [Float]? {
        guard let magArr = try? MLMultiArray(shape: [NSNumber(value: magnitude.count)], dataType: .float32) else {
            return nil
        }
        let inPtr = magArr.dataPointer.bindMemory(to: Float32.self, capacity: magnitude.count)
        for i in 0..<magnitude.count { inPtr[i] = magnitude[i] }

        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: [magInputName: MLFeatureValue(multiArray: magArr)]),
              let result = try? model.prediction(from: provider),
              let gainVal = result.featureValue(for: gainOutputName)?.multiArrayValue else { return nil }

        let cnt = gainVal.count
        var gains = [Float](repeating: 0, count: cnt)
        let gPtr = gainVal.dataPointer.bindMemory(to: Float32.self, capacity: cnt)
        for i in 0..<cnt { gains[i] = gPtr[i] }
        return gains
    }
}
