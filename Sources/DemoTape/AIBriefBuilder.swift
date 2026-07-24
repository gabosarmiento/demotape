import Foundation
import AVFoundation

/// Orchestrates the AI-brief pipeline end to end: transcribe the narration (reusing the cache),
/// read the event timeline, extract a few keyframes, ask a multimodal chat model to author the
/// brief, then assemble the self-contained `<name>-brief/` folder and a `.zip` fallback.
///
/// This is the I/O + network half; the pure logic lives in `AIBrief`. Runs synchronously — call it
/// off the main thread.
final class AIBriefBuilder {

    /// Everything the UI (or the CLI hook) needs after a successful build.
    struct Result {
        var bundleDir: URL
        var zipURL: URL
        var content: AIBrief.Content
        var briefMarkdown: String
        var agentPrompt: String   // for Kiro / Claude Code (points at the local folder)
        var webPrompt: String     // for web chat (brief inlined; attach screenshots)
    }

    private let stt: Captions.Config
    private let chat: AIBrief.Config

    init(stt: Captions.Config, chat: AIBrief.Config) {
        self.stt = stt
        self.chat = chat
    }

    // MARK: - Pipeline

    func build(for video: URL, progress: (Double) -> Void = { _ in }) throws -> Result {
        guard !chat.apiKey.isEmpty else { throw AIBrief.BriefError.missingKey }
        let paths = SourcePaths(source: video)

        // 1) Event timeline (optional — we degrade to a transcript-only brief if it's absent).
        progress(0.05)
        let metadata = loadMetadata(paths) ?? fallbackMetadata(for: video)

        // 2) Transcript: reuse the cache, else transcribe once (paid STT). A clip with no audio
        //    still yields a brief from its frames + events.
        progress(0.15)
        var cues: [CaptionCue] = Captions.loadTranscript(for: video) ?? []
        if cues.isEmpty {
            do { cues = try Captions().generate(for: video, config: stt).cues }
            catch Captions.CaptionsError.noAudioTrack { cues = [] }
        }

        // 3) Assemble the bundle directory (fresh) and extract keyframes into frames/.
        progress(0.35)
        let bundleDir = paths.directory.appendingPathComponent("\(paths.base)-brief", isDirectory: true)
        try resetDirectory(bundleDir)
        let framesDir = bundleDir.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        let times = AIBrief.keyframeTimestamps(metadata: metadata, cues: cues)
        let frames = FrameExtractor().extract(from: video, at: times, into: framesDir)

        // 4) The AI authors the brief from the fused transcript + activity timeline + screenshots.
        progress(0.55)
        let timeline = AIBrief.timelineText(metadata: metadata, cues: cues)
        let content = try requestBrief(timeline: timeline, frames: frames,
                                       framesDir: framesDir, duration: metadata.duration)

        // 5) Write the artifacts.
        progress(0.85)
        let sourceName = video.lastPathComponent
        let briefMD = AIBrief.briefMarkdown(content, sourceName: sourceName, duration: metadata.duration)
        let agentPrompt = AIBrief.handoffPrompt(content, bundleDirPath: bundleDir.path,
                                                briefMarkdown: briefMD, mode: .agent)
        let webPrompt = AIBrief.handoffPrompt(content, bundleDirPath: bundleDir.path,
                                              briefMarkdown: briefMD, mode: .web)

        try briefMD.write(to: bundleDir.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)
        try agentPrompt.write(to: bundleDir.appendingPathComponent("PROMPT.md"), atomically: true, encoding: .utf8)
        try AIBrief.manifestJSON(content, sourceName: sourceName, duration: metadata.duration)
            .write(to: bundleDir.appendingPathComponent("brief.json"), options: .atomic)
        copyTranscriptAndEvents(paths: paths, cues: cues, into: bundleDir)

        // 6) Zip the whole folder for the web-chat fallback.
        progress(0.95)
        let zipURL = paths.directory.appendingPathComponent("\(paths.base)-brief.zip")
        try zip(bundleDir, to: zipURL)

        progress(1.0)
        Log.write("AIBrief: \(frames.count) frames, intent=\(content.intent.rawValue) -> \(bundleDir.lastPathComponent)")
        return Result(bundleDir: bundleDir, zipURL: zipURL, content: content,
                      briefMarkdown: briefMD, agentPrompt: agentPrompt, webPrompt: webPrompt)
    }

    // MARK: - Inputs

    private func loadMetadata(_ paths: SourcePaths) -> RecordingMetadata? {
        guard let eventsURL = paths.events else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingMetadata.self, from: Data(contentsOf: eventsURL))
    }

    /// A minimal metadata stand-in (no events) so a picked file outside DemoTape still works.
    private func fallbackMetadata(for video: URL) -> RecordingMetadata {
        let seconds = CMTimeGetSeconds(AVAsset(url: video).duration)
        let dur = seconds.isFinite && seconds > 0 ? seconds : 0
        return RecordingMetadata(
            startedAt: Date(), duration: dur, capturedKeystrokes: false,
            cameraStartOffset: nil, eventTimeOffset: nil,
            display: DisplayInfo(pointWidth: 0, pointHeight: 0, pixelWidth: 0, pixelHeight: 0, scale: 1),
            cursor: [], clicks: [], scrolls: [], keys: [])
    }

    // MARK: - The AI calls (two-pass, so on-screen text can't hijack the summary)

    /// Pass 1 authors the brief from the transcript + activity ALONE (no images), then pass 2 uses
    /// the screenshots only to caption each frame. Splitting the calls guarantees the summary
    /// follows what the developer said, not text that happens to be visible on screen.
    private func requestBrief(timeline: String, frames: [AIBrief.Frame],
                              framesDir: URL, duration: Double) throws -> AIBrief.Content {
        // Pass 1: text-only intent analysis.
        let timelineText = timeline.isEmpty ? "(no narration or activity captured)" : timeline
        let coreText = try chatCompletion(messages: [
            ["role": "system", "content": AIBrief.briefSystemPrompt(duration: duration)],
            ["role": "user", "content": "Timeline (SAY = narration, DO = on-screen activity):\n\n\(timelineText)"]
        ])
        guard var content = AIBrief.parseBrief(fromContent: coreText, frames: frames) else {
            throw AIBrief.BriefError.decode("model did not return usable JSON")
        }

        // Pass 2: caption the frames (skipped when there are none).
        guard !frames.isEmpty else { return content }
        var userParts: [[String: Any]] = [[
            "type": "text",
            "text": "Here are the \(frames.count) screenshots, in order."
        ]]
        for f in frames {
            let fileURL = framesDir.appendingPathComponent(f.filename)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            userParts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/png;base64,\(data.base64EncodedString())"]
            ])
        }
        let context = content.title + (content.summary.isEmpty ? "" : " — \(content.summary)")
        // Frame notes are a nicety; if the captioning call fails, keep the brief without them.
        if let notesText = try? chatCompletion(messages: [
            ["role": "system", "content": AIBrief.frameNotesSystemPrompt(frameCount: frames.count, context: context)],
            ["role": "user", "content": userParts]
        ]) {
            let notes = AIBrief.parseFrameNotes(fromContent: notesText)
            content.frames = AIBrief.attachNotes(notes, to: frames)
        }
        return content
    }

    /// Sends one chat-completions request and returns the assistant message text. `messages` uses
    /// the OpenAI wire format (string or multimodal-parts content).
    private func chatCompletion(messages: [[String: Any]]) throws -> String {
        var base = chat.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw AIBrief.BriefError.api("bad URL") }

        let body: [String: Any] = ["model": chat.model, "temperature": 0.2, "messages": messages]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(chat.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var respData: Data?, respErr: Error?, http: HTTPURLResponse?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, e in
            respData = d; respErr = e; http = r as? HTTPURLResponse; sema.signal()
        }.resume()
        sema.wait()

        if let respErr = respErr { throw AIBrief.BriefError.network(respErr.localizedDescription) }
        guard let http = http else { throw AIBrief.BriefError.network("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AIBrief.BriefError.api("HTTP \(http.statusCode): \((respData.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(300))")
        }
        guard let data = respData else { throw AIBrief.BriefError.decode("empty body") }
        struct ChatResp: Decodable {
            struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(ChatResp.self, from: data),
              let text = decoded.choices.first?.message.content else {
            throw AIBrief.BriefError.decode("no choices")
        }
        return text
    }

    // MARK: - Files

    private func resetDirectory(_ dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func copyTranscriptAndEvents(paths: SourcePaths, cues: [CaptionCue], into bundleDir: URL) {
        let srtDest = bundleDir.appendingPathComponent("transcript.srt")
        if let existing = try? String(contentsOf: paths.srtURL, encoding: .utf8), !existing.isEmpty {
            try? existing.write(to: srtDest, atomically: true, encoding: .utf8)
        } else if !cues.isEmpty {
            try? Captions.srtString(cues).write(to: srtDest, atomically: true, encoding: .utf8)
        }
        if let events = paths.events, let data = try? Data(contentsOf: events) {
            try? data.write(to: bundleDir.appendingPathComponent("events.json"), options: .atomic)
        }
    }

    /// Zips a folder using the system `ditto` (no third-party dependency). `--keepParent` puts the
    /// folder itself inside the archive so it unzips to `<name>-brief/…`.
    private func zip(_ dir: URL, to zipURL: URL) throws {
        try? FileManager.default.removeItem(at: zipURL)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", dir.path, zipURL.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw AIBrief.BriefError.api("could not create zip (ditto exited \(proc.terminationStatus))")
        }
    }
}
