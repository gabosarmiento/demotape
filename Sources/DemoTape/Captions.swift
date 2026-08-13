import Foundation
import AVFoundation

/// A single spoken word with its own timing — powers word-by-word animated captions.
struct CaptionWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// A single subtitle cue. `words` (optional) carries per-word timing when the transcription
/// provided it, enabling karaoke/pop animation; older cached transcripts simply omit it.
struct CaptionCue: Codable, Equatable {
    var start: Double   // seconds
    var end: Double     // seconds
    var text: String
    var words: [CaptionWord]?
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
        // A key is required only for hosted providers. Local servers (localhost) run keyless, so
        // an empty key against a local endpoint is fine; a remote 401 is surfaced as an API error.
        if config.apiKey.isEmpty && !Settings.isLocalHost(urlString: config.baseURL) {
            throw CaptionsError.missingKey
        }
        let audio = try extractAudio(from: video)
        defer { try? FileManager.default.removeItem(at: audio) }
        let cues = try transcribe(audio: audio, config: config)

        let paths = SourcePaths(source: video)
        paths.ensureSourceDir()
        let srt = paths.srtURL
        let vtt = paths.vttURL
        try Captions.writeSRT(cues, to: srt)
        try Captions.writeVTT(cues, to: vtt)
        Captions.saveTranscript(cues, for: video)   // cache so we don't re-transcribe
        Log.write("Captions: \(cues.count) cues -> \(srt.lastPathComponent), \(vtt.lastPathComponent)")
        return (srt, vtt, cues)
    }

    // MARK: - Transcript cache (idempotency)

    /// Path of the cached transcript for a video, keyed to the EXACT file.
    ///
    /// A transcript's cue times only fit the audio timeline they were made from. The recording's
    /// shared `.source/<base>...` key strips `.tight` and `.voiceover`, so a sped-up Auto-Cut and its
    /// original — or a video and its re-voiced version — collapsed to one transcript, and captioning
    /// the derivative reused the original's times: every cue landed in the wrong place. Keying by the
    /// file's own stem keeps each timeline's transcript to itself, which is also exactly the rule the
    /// user wants: a different file gets transcribed, not reused.
    static func transcriptURL(for video: URL) -> URL {
        var stem = video.deletingPathExtension().lastPathComponent
        // Strip only markers that DON'T change the audio timeline, so `styled`, `captioned` and
        // `avatar` renders share one transcript (correct — same timing, and it keeps the existing
        // `<base>.transcript.json` on disk). Keep `.tight` (sped up / silence-cut) and `.voiceover`
        // (re-narrated), and any language tag, as their OWN transcripts — those timelines differ, and
        // sharing them was the bug where a derivative showed the original's cue times.
        for marker in [".styled", ".captioned", ".avatar"] {
            stem = stem.replacingOccurrences(of: marker, with: "")
        }
        return SourcePaths(source: video).sourceDir.appendingPathComponent("\(stem).transcript.json")
    }

    /// Legacy sibling path (pre-folder layout), per-file, checked so a not-yet-migrated recording
    /// isn't re-transcribed (and re-charged).
    private static func legacyTranscriptURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    /// Loads the cached transcript for THIS file if present. No cross-derivative fallback: reusing a
    /// transcript from a differently-timed file is the bug this avoids, so a file with no cache of its
    /// own is re-transcribed rather than shown someone else's cue times.
    static func loadTranscript(for video: URL) -> [CaptionCue]? {
        for url in [transcriptURL(for: video), legacyTranscriptURL(for: video)] {
            if let data = try? Data(contentsOf: url),
               let cues = try? JSONDecoder().decode([CaptionCue].self, from: data) {
                return cues
            }
        }
        return nil
    }

    /// Parses SRT text into cues (for reusing sidecars that predate the JSON cache).
    static func parseSRT(_ text: String) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIdx].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = srtSeconds(parts[0]), let end = srtSeconds(parts[1]) else { continue }
            let body = lines[(timingIdx + 1)...].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(CaptionCue(start: start, end: end, text: body)) }
        }
        return cues
    }

    private static func srtSeconds(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let hms = t.components(separatedBy: ":")
        guard hms.count == 3, let h = Double(hms[0]), let m = Double(hms[1]), let sec = Double(hms[2])
        else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Makes each cue's word timings cover its full text.
    ///
    /// Whisper's word list can be SHORTER than the segment text — it routinely drops the last word or
    /// two ("…you give it a" for text "…you give it a boundary."), even though the word was spoken.
    /// Anything drawn word-by-word from `words` then silently loses that word. Here the missing tail is
    /// re-attached: leading tokens keep their real timing, the dropped trailing tokens are timed into
    /// the gap before the next cue (where they were actually said), and the cue's end is extended to
    /// cover them — clamped to the next cue so two captions never overlap.
    static func reconcile(_ cues: [CaptionCue]) -> [CaptionCue] {
        let sorted = cues.sorted { $0.start < $1.start }
        return sorted.enumerated().map { i, cue in
            let nextStart = i + 1 < sorted.count ? sorted[i + 1].start : .greatestFiniteMagnitude
            return reconcileCue(cue, nextStart: nextStart)
        }
    }

    static func reconcileCue(_ cue: CaptionCue, nextStart: Double) -> CaptionCue {
        let tokens = cue.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let timed = cue.words ?? []
        // No per-word timing at all: leave it: the burner synthesizes across the full cue. Only cues
        // that HAVE timings but are missing their tail need repair here.
        guard !tokens.isEmpty, !timed.isEmpty else { return cue }

        // Timing already covers every token. Re-sync each word's TEXT from the (possibly edited) cue
        // text, keeping its timing. Editing a cue in the Subtitles tab updates `cue.text` but not
        // `cue.words`; without this re-sync, word-by-word styles keep rendering the stale per-word
        // text — e.g. a line fixed from "Kif" to "Kiff" still burned in as "Kif". Extra timings past
        // the (now shorter) token list are dropped so a shortened edit doesn't render leftover words.
        if timed.count >= tokens.count {
            let words = (0..<tokens.count).map {
                CaptionWord(text: tokens[$0], start: timed[$0].start, end: timed[$0].end)
            }
            let end = min(max(cue.end, words.last?.end ?? cue.end), nextStart)
            return CaptionCue(start: cue.start, end: end, text: cue.text, words: words)
        }

        // Incomplete. Leading tokens keep their timing (text taken from the segment so it's exact);
        // the dropped tail is spread through the gap up to the next cue.
        var words = (0..<timed.count).map {
            CaptionWord(text: $0 < tokens.count ? tokens[$0] : timed[$0].text,
                        start: timed[$0].start, end: timed[$0].end)
        }
        let missing = tokens[timed.count...].joined(separator: " ")
        let lastEnd = timed.last?.end ?? cue.start
        // Give the tail real time, but don't let it linger far into the gap.
        let tailEnd = min(nextStart, lastEnd + Double(tokens.count - timed.count) * 0.6 + 0.4)
        words += synthesizeWords(text: missing, start: lastEnd, end: max(tailEnd, lastEnd + 0.01))
        let end = min(max(cue.end, words.last?.end ?? cue.end), nextStart)
        return CaptionCue(start: cue.start, end: end, text: cue.text, words: words)
    }

    /// Splits text into words with even, speaking-rate timings across `[start, end]` — the fallback
    /// when a cue has no word timings at all, and the timer for a reconciled tail.
    static func synthesizeWords(text: String, start: Double, end: Double,
                                charactersPerSecond: Double = 14, minWordDuration: Double = 0) -> [CaptionWord] {
        CaptionBurner.synthesizeWords(text: text, start: start, end: end,
                                      charactersPerSecond: charactersPerSecond, minWordDuration: minWordDuration)
    }

    /// Saves/updates the cached transcript.
    static func saveTranscript(_ cues: [CaptionCue], for video: URL) {
        guard let data = try? JSONEncoder().encode(cues) else { return }
        SourcePaths(source: video).ensureSourceDir()
        try? data.write(to: transcriptURL(for: video), options: .atomic)
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
        struct Word: Decodable { let word: String; let start: Double; let end: Double }
        let text: String
        let segments: [Segment]?
        let words: [Word]?
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
            let allWords = (decoded.words ?? []).map {
                CaptionWord(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end)
            }.filter { !$0.text.isEmpty }

            func words(in start: Double, _ end: Double) -> [CaptionWord]? {
                guard !allWords.isEmpty else { return nil }
                // A word belongs to the cue whose time range contains its midpoint.
                let inRange = allWords.filter { let m = ($0.start + $0.end) / 2; return m >= start && m < end }
                return inRange.isEmpty ? nil : inRange
            }

            if let segments = decoded.segments, !segments.isEmpty {
                return segments.map {
                    CaptionCue(start: $0.start, end: $0.end,
                               text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                               words: words(in: $0.start, $0.end))
                }.filter { !$0.text.isEmpty }
            }
            let whole = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? [] : [CaptionCue(start: 0, end: 0, text: whole, words: allWords.isEmpty ? nil : allWords)]
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
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
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
        // Ask for word-level timing (for animated captions) plus segments. Providers that don't
        // support this simply ignore it and return segments only.
        appendField("timestamp_granularities[]", "segment")
        appendField("timestamp_granularities[]", "word")
        if !config.language.isEmpty { appendField("language", config.language) }
        body.append("--\(boundary)--\r\n")
        req.httpBody = body

        // Retries 429/5xx — see HTTPRetry. Transcription is a single call, but it's the one users hit
        // right after a render, when a provider may still be throttling the verification calls.
        let data: Data
        let http: HTTPURLResponse
        do { (data, http) = try HTTPRetry.send(req, label: "transcribe") }
        catch { throw CaptionsError.network(error.localizedDescription) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw CaptionsError.api("HTTP \(http.statusCode): \(msg.prefix(500))")
        }
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
