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
        var previewURL: String = ""   // ElevenLabs sample clip, for auditioning the voice
        var label: String { accent.isEmpty ? name : "\(name) (\(accent))" }
    }

    enum VoiceoverError: LocalizedError {
        case missingKey, network(String), api(String), noVideoTrack, synthFailed(String), muxFailed(String)
        /// ElevenLabs rejected the request because the account is out of credits. `detail` carries
        /// the "you have N credits remaining, M required" note when the API provides it.
        case quotaExceeded(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "No ElevenLabs API key configured."
            case .network(let m): return "Network error: \(m)"
            case .api(let m): return "ElevenLabs API error: \(m)"
            case .noVideoTrack: return "The video has no video track."
            case .synthFailed(let m): return "Voice synthesis failed: \(m)"
            case .muxFailed(let m): return "Couldn't attach the voiceover: \(m)"
            case .quotaExceeded(let m):
                return "Your ElevenLabs account is out of credits, so the voice couldn't be "
                    + "generated.\(m.isEmpty ? "" : " \(m)") Add credits at elevenlabs.io "
                    + "(Subscription), or set a different API key in AI Settings, then try again."
            }
        }
    }

    /// If an ElevenLabs error body is a quota rejection, returns a `.quotaExceeded` error with the
    /// human-readable "credits remaining / required" note; otherwise returns nil. Pure/testable.
    static func quotaError(status: Int, body: String) -> VoiceoverError? {
        let lower = body.lowercased()
        guard lower.contains("quota_exceeded") || lower.contains("quota of")
                || lower.contains("credits remaining") else { return nil }
        // Pull the readable sentence ElevenLabs includes, e.g.
        // "You have 49 credits remaining, while 112 credits are required for this request."
        var note = ""
        if let r = body.range(of: "You have", options: .caseInsensitive) {
            let tail = body[r.lowerBound...]
            if let dot = tail.firstIndex(of: ".") {
                note = String(tail[..<dot]) + "."
            } else {
                note = String(tail.prefix(140))
            }
        }
        return .quotaExceeded(note)
    }

    private let base = "https://api.elevenlabs.io/v1"

    // MARK: - Voices

    /// Parses the `/v1/voices` response into a simple voice list. Pure/testable.
    static func parseVoices(_ data: Data) throws -> [Voice] {
        struct Response: Decodable {
            struct V: Decodable {
                let voice_id: String; let name: String
                let labels: [String: String]?; let preview_url: String?
            }
            let voices: [V]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.voices.map {
            Voice(id: $0.voice_id, name: $0.name,
                  gender: $0.labels?["gender"] ?? "",
                  accent: $0.labels?["accent"] ?? "",
                  previewURL: $0.preview_url ?? "")
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
            if let q = Self.quotaError(status: http.statusCode, body: Self.body(data)) { throw q }
            throw VoiceoverError.api("HTTP \(http.statusCode): \(Self.body(data))")
        }
        return try Self.parseVoices(data)
    }

    // MARK: - Credit balance (proactive low-credit warning)

    /// Remaining ElevenLabs credits (characters). `remaining = limit - used`.
    struct Credits: Equatable {
        let used: Int
        let limit: Int
        var remaining: Int { max(0, limit - used) }
        /// A short human summary, e.g. "412 of 10,000 credits left".
        var summary: String {
            let f = NumberFormatter(); f.numberStyle = .decimal
            let rem = f.string(from: NSNumber(value: remaining)) ?? "\(remaining)"
            let lim = f.string(from: NSNumber(value: limit)) ?? "\(limit)"
            return "\(rem) of \(lim) credits left"
        }
    }

    /// Parses `/v1/user/subscription` into a credit balance. Pure/testable.
    static func parseCredits(_ data: Data) throws -> Credits {
        struct Response: Decodable { let character_count: Int; let character_limit: Int }
        let d = try JSONDecoder().decode(Response.self, from: data)
        return Credits(used: d.character_count, limit: d.character_limit)
    }

    /// Fetches the account's remaining credits. Read-only and free (doesn't consume credits), so
    /// it's safe to call when opening the voiceover window to warn before the user hits a wall.
    func fetchCredits(apiKey: String) throws -> Credits {
        guard !apiKey.isEmpty else { throw VoiceoverError.missingKey }
        guard let url = URL(string: base + "/user/subscription") else { throw VoiceoverError.api("bad URL") }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 30
        let (data, http) = try Self.sync(req)
        guard (200..<300).contains(http.statusCode) else {
            if let q = Self.quotaError(status: http.statusCode, body: Self.body(data)) { throw q }
            throw VoiceoverError.api("HTTP \(http.statusCode): \(Self.body(data))")
        }
        return try Self.parseCredits(data)
    }

    // MARK: - Provider abstraction (paid or local, pluggable)

    /// A TTS backend. Any of these produces audio bytes from text; the rest of the pipeline
    /// (assembly, muxing) is provider-agnostic.
    enum TTSProvider: String, Equatable {
        /// ElevenLabs hosted API (paid). Fixed endpoint, `xi-api-key`, expressive voice settings.
        case elevenLabs = "ElevenLabs"
        /// The OpenAI `/v1/audio/speech` contract — the widest-supported "standard". Works with
        /// OpenAI itself and most local servers (LocalAI, Kokoro-FastAPI, openedai-speech, …), so
        /// "run it locally" is just a base URL pointing at your Docker container.
        case openAICompatible = "OpenAI-compatible"
        /// A raw HTTP endpoint you control: `POST {baseURL}` with JSON `{text, voice, model}`,
        /// returns audio bytes. The escape hatch for wrapping any model (Chatterbox, Qwen-TTS, …).
        case custom = "Custom"

        init(name: String) { self = TTSProvider(rawValue: name) ?? .elevenLabs }
    }

    /// Everything needed to synthesize one clip, independent of where the request goes.
    struct TTSConfig: Equatable {
        var provider: TTSProvider = .elevenLabs
        /// Base URL for openAICompatible/custom (e.g. "http://localhost:8880/v1"). Ignored for
        /// ElevenLabs, which uses its fixed endpoint.
        var baseURL: String = ""
        var model: String = "eleven_multilingual_v2"
        /// Voice id (ElevenLabs) or voice name (openAI/custom, e.g. "alloy", "af_bella").
        var voice: String = ""
        /// Optional — local servers usually need no key. ElevenLabs requires one.
        var apiKey: String = ""

        /// Builds a config from environment variables, for the CLI/driver path (no GUI/Keychain).
        /// `DEMOTAPE_TTS_PROVIDER` selects the backend; falls back to ElevenLabs for compatibility.
        static func fromEnvironment(voice: String, env: [String: String] = ProcessInfo.processInfo.environment) -> TTSConfig {
            let provider = TTSProvider(name: env["DEMOTAPE_TTS_PROVIDER"] ?? "ElevenLabs")
            var c = TTSConfig(provider: provider)
            c.voice = voice
            switch provider {
            case .elevenLabs:
                c.model = env["DEMOTAPE_ELEVEN_MODEL"] ?? "eleven_multilingual_v2"
                c.apiKey = env["DEMOTAPE_TTS_KEY"] ?? env["DEMOTAPE_ELEVEN_KEY"] ?? ""
            case .openAICompatible, .custom:
                c.baseURL = env["DEMOTAPE_TTS_BASEURL"] ?? "http://localhost:8880/v1"
                c.model = env["DEMOTAPE_TTS_MODEL"] ?? "tts-1"
                c.apiKey = env["DEMOTAPE_TTS_KEY"] ?? ""
                if c.voice.isEmpty { c.voice = env["DEMOTAPE_TTS_VOICE"] ?? "alloy" }
            }
            return c
        }
    }

    /// Builds the HTTP request for a synthesis call. **Pure and testable** — no network. Encodes
    /// each provider's shape (URL, auth header, JSON body, expected audio format).
    static func buildSynthesisRequest(text: String, config: TTSConfig) throws -> URLRequest {
        let env = ProcessInfo.processInfo.environment
        func setting(_ key: String, _ dflt: Double) -> Double { env[key].flatMap(Double.init) ?? dflt }

        switch config.provider {
        case .elevenLabs:
            guard !config.apiKey.isEmpty else { throw VoiceoverError.missingKey }
            guard !config.voice.isEmpty,
                  let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(config.voice)") else {
                throw VoiceoverError.api("Pick an ElevenLabs voice first.")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 300
            req.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            // Expressive defaults: lower stability lets delivery vary (fully stable sounds robotic).
            let payload: [String: Any] = [
                "text": text,
                "model_id": config.model,
                "voice_settings": [
                    "stability": setting("DEMOTAPE_ELEVEN_STABILITY", 0.38),
                    "similarity_boost": setting("DEMOTAPE_ELEVEN_SIMILARITY", 0.75),
                    "style": setting("DEMOTAPE_ELEVEN_STYLE", 0.45),
                    "use_speaker_boost": true
                ]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return req

        case .openAICompatible:
            let base = config.baseURL.trimmingCharacters(in: .whitespaces).trimmedTrailingSlash
            guard let url = URL(string: base + "/audio/speech") else {
                throw VoiceoverError.api("Set a valid Base URL for the local/OpenAI TTS server.")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 300
            if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "model": config.model,
                "input": text,
                "voice": config.voice.isEmpty ? "alloy" : config.voice,
                "response_format": "mp3"
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return req

        case .custom:
            let base = config.baseURL.trimmingCharacters(in: .whitespaces).trimmedTrailingSlash
            guard let url = URL(string: base) else {
                throw VoiceoverError.api("Set a valid Base URL for your custom TTS endpoint.")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 300
            if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "text": text,
                "voice": config.voice,
                "model": config.model
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return req
        }
    }

    // MARK: - Synthesis

    /// Synthesizes `text` with the given provider config to a temporary MP3 file.
    func synthesize(text: String, config: TTSConfig) throws -> URL {
        let req = try Self.buildSynthesisRequest(text: text, config: config)
        let (data, http) = try Self.sync(req)
        guard (200..<300).contains(http.statusCode) else {
            if let q = Self.quotaError(status: http.statusCode, body: Self.body(data)) { throw q }
            throw VoiceoverError.api("HTTP \(http.statusCode): \(Self.body(data))")
        }
        guard !data.isEmpty else { throw VoiceoverError.synthFailed("the TTS server returned no audio") }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-vo-\(UUID().uuidString).mp3")
        try data.write(to: out)
        return out
    }

    /// Back-compat convenience: synthesize via ElevenLabs (the original signature).
    func synthesize(text: String, voiceId: String, model: String, apiKey: String) throws -> URL {
        try synthesize(text: text, config: TTSConfig(provider: .elevenLabs, model: model,
                                                     voice: voiceId, apiKey: apiKey))
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

    /// A single narration clip placed at a specific time in the video (for scene-synced demos).
    struct TimedClip { let url: URL; let at: Double }   // `at` in seconds from the video start

    /// Assembles a voiceover from several clips, each laid at its own offset — so a scripted
    /// walkthrough stays in sync with the on-screen actions (scene N's line begins exactly when
    /// scene N's action does). Video is passthrough. Returns the `…voiceover.mp4`.
    @discardableResult
    func assembleTimeline(video: URL, clips: [TimedClip]) throws -> URL {
        let out = Self.outputURL(for: video)
        try muxTimeline(video: video, clips: clips, to: out)
        return out
    }

    /// Muxes several audio clips at their offsets onto the video's picture (silence in the gaps).
    func muxTimeline(video: URL, clips: [TimedClip], to outURL: URL) throws {
        let videoAsset = AVAsset(url: video)
        guard let vTrack = videoAsset.tracks(withMediaType: .video).first else {
            throw VoiceoverError.noVideoTrack
        }
        let comp = AVMutableComposition()
        let vDur = videoAsset.duration
        guard let vComp = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VoiceoverError.muxFailed("video track")
        }
        try vComp.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vTrack, at: .zero)
        vComp.preferredTransform = vTrack.preferredTransform

        var tempM4As: [URL] = []
        defer { tempM4As.forEach { try? FileManager.default.removeItem(at: $0) } }
        if let aComp = comp.addMutableTrack(withMediaType: .audio,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
            var cursor = CMTime.zero
            for clip in clips.sorted(by: { $0.at < $1.at }) {
                // Passthrough export can't encode MP3 — transcode each clip to AAC/.m4a first.
                let m4a = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dt-clip-\(UUID().uuidString).m4a")
                do { try transcodeToM4A(clip.url, to: m4a) } catch { continue }
                tempM4As.append(m4a)
                let audioAsset = AVAsset(url: m4a)
                guard let aTrack = audioAsset.tracks(withMediaType: .audio).first else { continue }
                var start = CMTime(seconds: max(0, clip.at), preferredTimescale: 600)
                if start > vDur { continue }
                if start > cursor {           // pad the gap with silence
                    aComp.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: CMTimeSubtract(start, cursor)))
                } else {
                    start = cursor            // never overlap the previous clip
                }
                let avail = CMTimeSubtract(vDur, start)
                let dur = CMTimeMinimum(audioAsset.duration, avail)
                if dur <= .zero { continue }
                try aComp.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: aTrack, at: start)
                cursor = CMTimeAdd(start, dur)
            }
        }

        try? FileManager.default.removeItem(at: outURL)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
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
    func generate(video: URL, script: String, config: TTSConfig) throws -> VoiceoverResult {
        let mp3 = try synthesize(text: script, config: config)
        defer { try? FileManager.default.removeItem(at: mp3) }   // only the temp MP3 is transient
        return try assembleVoiceover(video: video, narrationAudio: mp3)
    }

    /// Back-compat convenience: generate via ElevenLabs (the original signature).
    @discardableResult
    func generate(video: URL, script: String, voiceId: String, model: String, apiKey: String) throws -> VoiceoverResult {
        try generate(video: video, script: script,
                     config: TTSConfig(provider: .elevenLabs, model: model, voice: voiceId, apiKey: apiKey))
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

private extension String {
    /// Drops one or more trailing slashes so we can append a path cleanly ("…/v1/" → "…/v1").
    var trimmedTrailingSlash: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
