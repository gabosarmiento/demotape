import Foundation
import AVFoundation

/// A single subtitle cue.
struct CaptionCue {
    var start: Double   // seconds
    var end: Double     // seconds
    var text: String
}

/// Generates captions for a recording using an OpenAI-compatible speech-to-text API
/// (OpenAI, Groq, or any compatible endpoint). Bring-your-own-key: nothing is sent
/// anywhere unless the user has configured a key and explicitly runs this.
///
/// Output is a `.srt` and `.vtt` sidecar next to the source video — usable by any
/// player, YouTube, or the Web Publish `<video>` embed. Burned-in captions and an
/// editable transcript build on top of these cues.
final class Captions {

    struct Config {
        /// API base, e.g. "https://api.openai.com/v1" or "https://api.groq.com/openai/v1".
        var baseURL: String
        /// Model id, e.g. "whisper-1" (OpenAI) or "whisper-large-v3" (Groq).
        var model: String
        var apiKey: String
        /// Optional ISO-639-1 language hint (e.g. "en"); empty = auto-detect.
        var language: String = ""
    }

    enum CaptionsError: LocalizedError {
        case noAudioTrack
        case audioExportFailed(String)
        case network(String)
        case api(String)
        case decode(String)
        case missingKey

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "The recording has no audio track to transcribe."
            case .audioExportFailed(let m): return "Couldn't extract audio: \(m)"
            case .network(let m): return "Network error: \(m)"
            case .api(let m): return "Transcription API error: \(m)"
            case .decode(let m): return "Couldn't read the transcription response: \(m)"
            case .missingKey: return "No API key configured for captions."
            }
        }
    }

    // MARK: - Full pipeline

    /// Transcribes `video` and writes `.srt` + `.vtt` sidecars next to it.
    /// Returns the written URLs. Runs synchronously; call off the main thread.
    @discardableResult
    func generate(for video: URL, config: Config) throws -> (srt: URL, vtt: URL, cues: [CaptionCue]) {
        guard !config.apiKey.isEmpty else { throw CaptionsError.missingKey }
        let audio = try extractAudio(from: video)
        defer { try? FileManager.default.removeItem(at: audio) }
        let cues = try transcribe(audio: audio, config: config)

        let base = video.deletingPathExtension()
        let srt = base.appendingPathExtension("srt")
        let vtt = base.appendingPathExtension("vtt")
        try Captions.writeSRT(cues, to: srt)
        try Captions.writeVTT(cues, to: vtt)
        Log.write("Captions: \(cues.count) cues -> \(srt.lastPathComponent), \(vtt.lastPathComponent)")
        return (srt, vtt, cues)
    }

    // MARK: - Audio extraction

    /// Exports the audio track to a temporary .m4a (accepted by Whisper-style APIs).
    func extractAudio(from video: URL) throws -> URL {
        let asset = AVAsset(url: video)
        guard asset.tracks(withMediaType: .audio).first != nil else { throw CaptionsError.noAudioTrack }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptionsError.audioExportFailed("no export session")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .m4a

        let sema = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sema.signal() }
        sema.wait()

        guard export.status == .completed else {
            throw CaptionsError.audioExportFailed(export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        }
        return out
    }

    // MARK: - Transcription (OpenAI-compatible /audio/transcriptions)

    private struct VerboseResponse: Decodable {
        struct Segment: Decodable { let start: Double; let end: Double; let text: String }
        let text: String
        let segments: [Segment]?
    }

    /// Builds the `/audio/transcriptions` endpoint from a base URL, tolerating a trailing
    /// slash. Returns nil for an empty/invalid base.
    static func transcriptionEndpoint(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/audio/transcriptions")
    }

    /// Parses an OpenAI-compatible `verbose_json` transcription response into cues.
    /// Falls back to a single whole-clip cue when the API returns no segments, and drops
    /// empty segments.
    static func parseCues(fromVerboseJSON data: Data) throws -> [CaptionCue] {
        do {
            let decoded = try JSONDecoder().decode(VerboseResponse.self, from: data)
            if let segments = decoded.segments, !segments.isEmpty {
                return segments.map {
                    CaptionCue(start: $0.start, end: $0.end,
                               text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }.filter { !$0.text.isEmpty }
            }
            let whole = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? [] : [CaptionCue(start: 0, end: 0, text: whole)]
        } catch {
            throw CaptionsError.decode(error.localizedDescription)
        }
    }

    func transcribe(audio: URL, config: Config) throws -> [CaptionCue] {
        guard let endpoint = Self.transcriptionEndpoint(baseURL: config.baseURL) else {
            throw CaptionsError.api("invalid base URL")
        }

        let boundary = "DemoTapeBoundary-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audio)
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        // File part.
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")
        // Fields.
        appendField("model", config.model)
        appendField("response_format", "verbose_json")
        if !config.language.isEmpty { appendField("language", config.language) }
        body.append("--\(boundary)--\r\n")
        req.httpBody = body

        var respData: Data?
        var respError: Error?
        var http: HTTPURLResponse?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            respData = data; respError = err; http = resp as? HTTPURLResponse; sema.signal()
        }.resume()
        sema.wait()

        if let respError { throw CaptionsError.network(respError.localizedDescription) }
        guard let http else { throw CaptionsError.network("no response") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = respData.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
            throw CaptionsError.api("HTTP \(http.statusCode): \(msg.prefix(500))")
        }
        guard let data = respData else { throw CaptionsError.decode("empty body") }
        return try Self.parseCues(fromVerboseJSON: data)
    }

    // MARK: - Sidecar writers

    static func srtString(_ cues: [CaptionCue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTime(cue.start)) --> \(srtTime(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    static func vttString(_ cues: [CaptionCue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(vttTime(cue.start)) --> \(vttTime(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    static func writeSRT(_ cues: [CaptionCue], to url: URL) throws {
        try srtString(cues).write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeVTT(_ cues: [CaptionCue], to url: URL) throws {
        try vttString(cues).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func hms(_ t: Double) -> (Int, Int, Int, Int) {
        let clamped = max(0, t)
        let ms = Int((clamped * 1000).rounded())
        return (ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }
    private static func srtTime(_ t: Double) -> String {
        let (h, m, s, ms) = hms(t)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
    private static func vttTime(_ t: Double) -> String {
        let (h, m, s, ms) = hms(t)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
