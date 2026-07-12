import Foundation
import AVFoundation

/// The result of generating a voiceover. Besides the finished video, the synthesized narration
/// audio is preserved as a durable file next to the output (`…voiceover.narration.m4a`), so a
/// later step — e.g. avatar generation — can reuse the exact narration without re-synthesizing.
/// The narration is NOT deleted automatically; call `cleanupNarration()` when it's no longer
/// needed (after the avatar step finishes, or the user declines it).
struct VoiceoverResult: Equatable {
    let videoURL: URL
    let narrationAudioURL: URL

    /// Explicitly remove the durable narration audio. Safe to call more than once.
    func cleanupNarration() {
        try? FileManager.default.removeItem(at: narrationAudioURL)
    }
}

/// Lean ElevenLabs voiceover: take a script (typed, from the transcript, or loaded from a
/// .txt file), synthesize speech, and lay it over the video from the start — replacing the
/// original audio. No timeline; the user writes/paces the script to match their recording.
///
/// Bring-your-own-key: nothing happens until the user adds an ElevenLabs key.
final class Voiceover {

    struct Voice: Identifiable, Equatable {
        let id: String       // voice_id
        let name: String
        let gender: String
        let accent: String
        var label: String { accent.isEmpty ? name : "\(name) (\(accent))" }
    }

    enum VoiceoverError: LocalizedError {
        case missingKey, network(String), api(String), noVideoTrack, synthFailed(String), muxFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "No ElevenLabs API key configured."
            case .network(let m): return "Network error: \(m)"
            case .api(let m): return "ElevenLabs API error: \(m)"
            case .noVideoTrack: return "The video has no video track."
            case .synthFailed(let m): return "Voice synthesis failed: \(m)"
            case .muxFailed(let m): return "Couldn't attach the voiceover: \(m)"
            }
        }
    }

    private let base = "https://api.elevenlabs.io/v1"

    // MARK: - Voices

    /// Parses the `/v1/voices` response into a simple voice list. Pure/testable.
    static func parseVoices(_ data: Data) throws -> [Voice] {
        struct Response: Decodable {
            struct V: Decodable { let voice_id: String; let name: String; let labels: [String: String]? }
            let voices: [V]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.voices.map {
            Voice(id: $0.voice_id, name: $0.name,
                  gender: $0.labels?["gender"] ?? "",
                  accent: $0.labels?["accent"] ?? "")
        }
    }

    func fetchVoices(apiKey: String) throws -> [Voice] {
        guard !apiKey.isEmpty else { throw VoiceoverError.missingKey }
        guard let url = URL(string: base + "/voices") else { throw VoiceoverError.api("bad URL") }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 60
        let (data, http) = try Self.sync(req)
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceoverError.api("HTTP \(http.statusCode): \(Self.body(data))")
        }
        return try Self.parseVoices(data)
    }

    // MARK: - Synthesis

    /// Synthesizes `text` with `voiceId` to a temporary MP3 file.
    func synthesize(text: String, voiceId: String, model: String, apiKey: String) throws -> URL {
        guard !apiKey.isEmpty else { throw VoiceoverError.missingKey }
        guard let url = URL(string: "\(base)/text-to-speech/\(voiceId)") else {
            throw VoiceoverError.api("bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let payload: [String: Any] = ["text": text, "model_id": model]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, http) = try Self.sync(req)
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceoverError.api("HTTP \(http.statusCode): \(Self.body(data))")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-vo-\(UUID().uuidString).mp3")
        try data.write(to: out)
        return out
    }

    // MARK: - Assembly (local; no network — testable with fixtures)

    /// Derives the durable narration path (`…voiceover.narration.m4a`) beside the output for
    /// a given source video, using the same base-name rule as the voiceover output.
    static func narrationURL(for video: URL) -> URL {
        let base = video.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".styled", with: "")
        return video.deletingLastPathComponent().appendingPathComponent("\(base).voiceover.narration.m4a")
    }

    /// Derives the voiceover output path (`…voiceover.mp4`) beside the source video.
    static func outputURL(for video: URL) -> URL {
        let base = video.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".styled", with: "")
        return video.deletingLastPathComponent().appendingPathComponent("\(base).voiceover.mp4")
    }

    /// Assembles the final voiceover from an already-synthesized narration audio file (any
    /// AVFoundation-readable format). Writes a DURABLE narration `.m4a` beside the output so it
    /// survives for a later avatar step, then muxes it over the video (video passthrough, no
    /// re-encode). The narration audio is intentionally NOT deleted here.
    @discardableResult
    func assembleVoiceover(video: URL, narrationAudio: URL) throws -> VoiceoverResult {
        let out = Self.outputURL(for: video)
        let narration = Self.narrationURL(for: video)
        try transcodeToM4A(narrationAudio, to: narration)
        try muxNarration(video: video, narration: narration, to: out)
        return VoiceoverResult(videoURL: out, narrationAudioURL: narration)
    }

    /// Produces a new file with `video`'s picture (passthrough) and `narration` (an .m4a) as
    /// the audio, starting at t=0 and clamped to the video's length.
    func muxNarration(video: URL, narration m4a: URL, to outURL: URL) throws {
        let videoAsset = AVAsset(url: video)
        let audioAsset = AVAsset(url: m4a)
        guard let vTrack = videoAsset.tracks(withMediaType: .video).first else {
            throw VoiceoverError.noVideoTrack
        }
        let comp = AVMutableComposition()
        let vDuration = videoAsset.duration
        let full = CMTimeRange(start: .zero, duration: vDuration)

        guard let vComp = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VoiceoverError.muxFailed("video track")
        }
        try vComp.insertTimeRange(full, of: vTrack, at: .zero)
        vComp.preferredTransform = vTrack.preferredTransform

        if let aTrack = audioAsset.tracks(withMediaType: .audio).first,
           let aComp = comp.addMutableTrack(withMediaType: .audio,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
            // Lay the narration from the start, clamped to the video length.
            let aDur = min(audioAsset.duration, vDuration)
            try aComp.insertTimeRange(CMTimeRange(start: .zero, duration: aDur), of: aTrack, at: .zero)
        }

        try? FileManager.default.removeItem(at: outURL)
        guard let export = AVAssetExportSession(asset: comp,
                                                presetName: AVAssetExportPresetPassthrough) else {
            throw VoiceoverError.muxFailed("no export session")
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        let sema = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sema.signal() }
        sema.wait()
        guard export.status == .completed else {
            throw VoiceoverError.muxFailed(export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        }
        Log.write("Voiceover: wrote \(outURL.lastPathComponent)")
    }

    /// Full convenience pipeline: script -> speech -> new …voiceover.mp4 (plus durable
    /// …voiceover.narration.m4a) next to the video. Returns both URLs.
    @discardableResult
    func generate(video: URL, script: String, voiceId: String, model: String, apiKey: String) throws -> VoiceoverResult {
        let mp3 = try synthesize(text: script, voiceId: voiceId, model: model, apiKey: apiKey)
        defer { try? FileManager.default.removeItem(at: mp3) }   // only the temp MP3 is transient
        return try assembleVoiceover(video: video, narrationAudio: mp3)
    }

    // MARK: - Helpers

    /// Re-encodes any AVFoundation-readable audio to AAC/.m4a at the given destination.
    private func transcodeToM4A(_ input: URL, to out: URL) throws {
        let asset = AVAsset(url: input)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw VoiceoverError.synthFailed("no m4a export session")
        }
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .m4a
        let sema = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sema.signal() }
        sema.wait()
        guard export.status == .completed else {
            throw VoiceoverError.synthFailed(export.error?.localizedDescription ?? "m4a status \(export.status.rawValue)")
        }
    }

    private static func sync(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        var outData: Data?; var outErr: Error?; var http: HTTPURLResponse?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, e in
            outData = d; outErr = e; http = r as? HTTPURLResponse; sema.signal()
        }.resume()
        sema.wait()
        if let outErr { throw VoiceoverError.network(outErr.localizedDescription) }
        guard let http, let outData else { throw VoiceoverError.network("no response") }
        return (outData, http)
    }

    private static func body(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.prefix(300).description ?? "no body"
    }
}
