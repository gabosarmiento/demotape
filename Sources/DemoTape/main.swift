import AppKit

// DemoTape — a lightweight, local-first screen recorder for macOS 12+ (Intel & Apple Silicon).
// Phase 1: menu-bar app that records the main display to an H.264 .mov file.
//
// Note: MenuBarExtra (SwiftUI) requires macOS 13, so the menu bar is built with
// AppKit's NSStatusItem to stay compatible with Monterey 12.7.6.

// Headless render mode for testing:  DemoTape --render <video.mov> <output.mov>
// Reads the matching .events.json sidecar. No GUI, no permissions.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render"), args.count > i + 2 {
    let videoURL = URL(fileURLWithPath: args[i + 1])
    let outURL = URL(fileURLWithPath: args[i + 2])
    let sidecar = videoURL.deletingPathExtension().appendingPathExtension("events.json")
    do {
        let data = try Data(contentsOf: sidecar)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RecordingMetadata.self, from: data)
        let camURL = videoURL.deletingPathExtension().appendingPathExtension("cam.mov")
        let camera = FileManager.default.fileExists(atPath: camURL.path) ? camURL : nil
        var style = VideoRenderer.Style()
        if let brand = ProcessInfo.processInfo.environment["DEMOTAPE_BRAND_IMAGE"],
           FileManager.default.fileExists(atPath: brand) {
            style.brandingImageURL = URL(fileURLWithPath: brand)   // headless branding smoke-test
        }
        if let ex = ProcessInfo.processInfo.environment["DEMOTAPE_EXPORT"] {  // e.g. 1080x1350
            let parts = ex.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { style.exportSize = CGSize(width: parts[0], height: parts[1]) }
        }
        try VideoRenderer().render(videoURL: videoURL, metadata: metadata, cameraURL: camera, to: outURL, style: style)
        print("rendered: \(outURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("render error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless template apply:  DemoTape --template <master.mp4> <templateID> <output.mp4>
// Derives the sibling .cam.mov if present; branding via DEMOTAPE_BRAND_IMAGE. No GUI.
if let i = args.firstIndex(of: "--template"), args.count > i + 3 {
    if #available(macOS 12.3, *) {
        let master = URL(fileURLWithPath: args[i + 1])
        let id = args[i + 2]
        let out = URL(fileURLWithPath: args[i + 3])
        guard let template = VideoTemplate.byID(id) else {
            let ids = VideoTemplate.catalog.map { $0.id }.joined(separator: ", ")
            FileHandle.standardError.write("template error: unknown id '\(id)'. Options: \(ids)\n".data(using: .utf8)!)
            exit(1)
        }
        var base = master.deletingPathExtension().lastPathComponent
        if base.hasSuffix(".styled") { base = String(base.dropLast(".styled".count)) }
        let camCandidate = master.deletingLastPathComponent().appendingPathComponent(base + ".cam.mov")
        let cam = FileManager.default.fileExists(atPath: camCandidate.path) ? camCandidate : nil
        let brand = ProcessInfo.processInfo.environment["DEMOTAPE_BRAND_IMAGE"].map { URL(fileURLWithPath: $0) }
        do {
            try TemplateComposer().compose(master: master, cam: cam, branding: brand,
                                           template: template, to: out) { _ in }
            print("template: \(out.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write("template error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    } else {
        exit(1)
    }
}

// Headless: pad a photo with headroom for avatar generation.  DemoTape --avatar-prep-image <in> <out.png>
if let i = args.firstIndex(of: "--avatar-prep-image"), args.count > i + 2 {
    let out = AvatarImagePrep.paddedForHeadroom(URL(fileURLWithPath: args[i + 1]))
    let dest = URL(fileURLWithPath: args[i + 2])
    try? FileManager.default.removeItem(at: dest)
    do { try FileManager.default.copyItem(at: out, to: dest); print("prepped: \(dest.path)"); exit(0) }
    catch { FileHandle.standardError.write("prep error: \(error)\n".data(using: .utf8)!); exit(1) }
}

// Headless: assemble a voiceover.mp4 from a video + an existing narration audio file (no TTS).
// DemoTape --voiceover-assemble <video> <audioFile>
if let i = args.firstIndex(of: "--voiceover-assemble"), args.count > i + 2 {
    let video = URL(fileURLWithPath: args[i + 1])
    let audio = URL(fileURLWithPath: args[i + 2])
    do {
        let r = try Voiceover().assembleVoiceover(video: video, narrationAudio: audio)
        print("voiceover: \(r.videoURL.path)\nnarration: \(r.narrationAudioURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("assemble error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless avatar composite:  DemoTape --avatar-composite <screen.mp4> <avatar.mp4> <out.mp4> [left|right] [chroma|photo]
// Composites a background-removed (chroma) or webcam-style (photo) avatar over the screen video.
if let i = args.firstIndex(of: "--avatar-composite"), args.count > i + 3 {
    if #available(macOS 12.3, *) {
        let screen = URL(fileURLWithPath: args[i + 1])
        let avatar = URL(fileURLWithPath: args[i + 2])
        let out = URL(fileURLWithPath: args[i + 3])
        let pos: AvatarPosition = (args.count > i + 4 && args[i + 4] == "left") ? .bottomLeft : .bottomRight
        let mode = args.count > i + 5 ? args[i + 5] : "photo"
        // Photo path chroma-keys too: HeyGen returns green for padded photos (keyed to a clean
        // cutout on the frosted disc); if a render keeps the room, keying green is a harmless no-op.
        let remover: BackgroundRemover = ChromaKeyRemover()
        var layout = AvatarCompositor.Layout()
        if mode == "chroma" {
            layout.shape = .cutout
            layout.position = pos
        } else {
            // Webcam-style circle at the webcam's slot, on a frosted disc.
            layout.shape = .circle
            layout.centerX = CGFloat(Settings.webcamPositionX)
            layout.centerY = CGFloat(Settings.webcamPositionY)
            layout.diameterFraction = CGFloat(Settings.webcamSize)
        }
        do {
            try AvatarCompositor(remover: remover).compose(screen: screen, avatar: avatar, to: out, layout: layout)
            print("avatar: \(out.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write("avatar-composite error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    } else { exit(1) }
}

// Headless captions test:  DemoTape --captions <input.mp4>
// Uses DEMOTAPE_STT_KEY (and optional DEMOTAPE_STT_BASEURL / DEMOTAPE_STT_MODEL) from
// the environment so it runs without the GUI/Keychain. Writes .srt + .vtt sidecars.
if let i = args.firstIndex(of: "--captions"), args.count > i + 1 {
    let input = URL(fileURLWithPath: args[i + 1])
    let env = ProcessInfo.processInfo.environment
    let key = env["DEMOTAPE_STT_KEY"] ?? Keychain.get(account: Keychain.sttAPIKeyAccount) ?? ""
    guard !key.isEmpty else {
        FileHandle.standardError.write("captions error: no API key (set DEMOTAPE_STT_KEY)\n".data(using: .utf8)!)
        exit(1)
    }
    let config = Captions.Config(
        baseURL: env["DEMOTAPE_STT_BASEURL"] ?? "https://api.openai.com/v1",
        model: env["DEMOTAPE_STT_MODEL"] ?? "whisper-1",
        apiKey: key,
        language: env["DEMOTAPE_STT_LANG"] ?? "")
    do {
        let result = try Captions().generate(for: input, config: config)
        print("captions: \(result.srt.path)\n\(result.vtt.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("captions error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless AI brief:  DemoTape --brief <input.mov|.mp4>
// Turns a short "explain it to the AI" recording into a <name>-brief/ folder (+ .zip) with an
// AI-authored BRIEF.md, keyframes, transcript, and a copy-paste handoff prompt. Uses
// DEMOTAPE_STT_KEY for transcription and the same key for the chat model
// (DEMOTAPE_BRIEF_MODEL, default gpt-4o-mini). No GUI/Keychain needed.
if let i = args.firstIndex(of: "--brief"), args.count > i + 1 {
    if #available(macOS 12.3, *) {
        let input = URL(fileURLWithPath: args[i + 1])
        let env = ProcessInfo.processInfo.environment
        let key = env["DEMOTAPE_STT_KEY"] ?? Keychain.get(account: Keychain.sttAPIKeyAccount) ?? ""
        guard !key.isEmpty else {
            FileHandle.standardError.write("brief error: no API key (set DEMOTAPE_STT_KEY)\n".data(using: .utf8)!)
            exit(1)
        }
        let baseURL = env["DEMOTAPE_STT_BASEURL"] ?? "https://api.openai.com/v1"
        let stt = Captions.Config(baseURL: baseURL, model: env["DEMOTAPE_STT_MODEL"] ?? "whisper-1",
                                  apiKey: key, language: env["DEMOTAPE_STT_LANG"] ?? "")
        let chat = AIBrief.Config(baseURL: baseURL, model: env["DEMOTAPE_BRIEF_MODEL"] ?? "gpt-4o-mini", apiKey: key)
        do {
            let r = try AIBriefBuilder(stt: stt, chat: chat).build(for: input) { p in
                FileHandle.standardError.write("brief: \(Int(p * 100))%\r".data(using: .utf8)!)
            }
            print("\nbrief: \(r.bundleDir.path)\nzip:   \(r.zipURL.path)\n\n--- PROMPT ---\n\(r.agentPrompt)")
            exit(0)
        } catch {
            FileHandle.standardError.write("brief error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    } else { exit(1) }
}

// Headless self-verification:  DemoTape --verify <video> <spec.json>
// spec.json: {"scenes":[{"at":3.8,"say":"I'll click Get started"}, …]}
// Grabs the frame at each scene and asks a vision model whether it matches the narration. Prints a
// JSON report and exits 0 if every scene passed, 2 otherwise (so a driver can gate on it).
if let i = args.firstIndex(of: "--verify"), args.count > i + 2 {
    if #available(macOS 12.3, *) {
        let video = URL(fileURLWithPath: args[i + 1])
        let specURL = URL(fileURLWithPath: args[i + 2])
        let env = ProcessInfo.processInfo.environment
        let key = env["DEMOTAPE_STT_KEY"] ?? Keychain.get(account: Keychain.sttAPIKeyAccount) ?? ""
        guard !key.isEmpty else {
            FileHandle.standardError.write("verify error: no API key (set DEMOTAPE_STT_KEY)\n".data(using: .utf8)!)
            exit(1)
        }
        let config = AIBrief.Config(baseURL: env["DEMOTAPE_STT_BASEURL"] ?? "https://api.openai.com/v1",
                                    model: env["DEMOTAPE_BRIEF_MODEL"] ?? "gpt-4o-mini", apiKey: key)
        struct Spec: Decodable { let scenes: [DemoVerifier.Scene] }
        do {
            let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: specURL))
            let report = try DemoVerifier.run(video: video, scenes: spec.scenes, config: config)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
            FileHandle.standardOutput.write(try enc.encode(report))
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            exit(report.pass ? 0 : 2)
        } catch {
            FileHandle.standardError.write("verify error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    } else { exit(1) }
}

// Headless scene-synced voiceover:  DemoTape --voiceover-timeline <video> <spec.json>
// spec.json: {"clips":[{"audio":"/path/a.mp3","at":0.0},{"audio":"/path/b.mp3","at":6.2}]}
// Lays each clip at its offset so a scripted walkthrough stays in sync with the actions.
if let i = args.firstIndex(of: "--voiceover-timeline"), args.count > i + 2 {
    let video = URL(fileURLWithPath: args[i + 1])
    let specURL = URL(fileURLWithPath: args[i + 2])
    struct Spec: Decodable { struct Clip: Decodable { let audio: String; let at: Double }; let clips: [Clip] }
    do {
        let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: specURL))
        let clips = spec.clips.map { Voiceover.TimedClip(url: URL(fileURLWithPath: $0.audio), at: $0.at) }
        let out = try Voiceover().assembleTimeline(video: video, clips: clips)
        print("voiceover: \(out.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("voiceover-timeline error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless cursor control for driven demos (so the real macOS cursor is visible in the capture,
// and optionally so clicks trigger DemoTape's auto-zoom):
//   DemoTape --cursor move  <x> <y>
//   DemoTape --cursor click <x> <y>
// Coordinates are global display points (top-left origin). "move" needs no permission; "click"
// posts a real mouse click (the controlling process needs Accessibility permission).
if let i = args.firstIndex(of: "--cursor"), args.count > i + 3 {
    let action = args[i + 1]
    let x = Double(args[i + 2]) ?? 0
    let y = Double(args[i + 3]) ?? 0
    let pt = CGPoint(x: x, y: y)
    // Glide from the current position with ease-in-out so it reads as a human hand, not a teleport.
    let start = CGEvent(source: nil)?.location ?? pt
    let steps = 26
    for s in 1...steps {
        let t = Double(s) / Double(steps)
        let e = t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t   // easeInOut
        CGWarpMouseCursorPosition(CGPoint(x: start.x + (pt.x - start.x) * e,
                                          y: start.y + (pt.y - start.y) * e))
        usleep(13_000)
    }
    CGWarpMouseCursorPosition(pt)
    CGAssociateMouseAndMouseCursorPosition(1)
    if action == "click" {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    print("cursor \(action) \(Int(x)) \(Int(y))")
    exit(0)
}

// Headless text-to-speech:  DemoTape --tts <script.txt> <out.mp3> [voice]
// Synthesizes narration only (no video). The provider is chosen by DEMOTAPE_TTS_PROVIDER:
//   (unset)/ElevenLabs      → ElevenLabs (paid). Key: DEMOTAPE_TTS_KEY or DEMOTAPE_ELEVEN_KEY.
//   OpenAI-compatible       → POST {DEMOTAPE_TTS_BASEURL}/audio/speech (local Docker, LocalAI, …).
//   Custom                  → POST {DEMOTAPE_TTS_BASEURL} with {text,voice,model}.
// This is what lets a demo run fully locally with no paid key.
if let i = args.firstIndex(of: "--tts"), args.count > i + 2 {
    let scriptURL = URL(fileURLWithPath: args[i + 1])
    let outURL = URL(fileURLWithPath: args[i + 2])
    let env = ProcessInfo.processInfo.environment
    let voiceArg = args.count > i + 3 ? args[i + 3] : (env["DEMOTAPE_ELEVEN_VOICE"] ?? env["DEMOTAPE_TTS_VOICE"] ?? "")
    var config = Voiceover.TTSConfig.fromEnvironment(voice: voiceArg)
    // For ElevenLabs, fall back to the stored Keychain key and a sensible default voice.
    if config.provider == .elevenLabs {
        if config.apiKey.isEmpty { config.apiKey = Keychain.get(account: Keychain.elevenAPIKeyAccount) ?? "" }
        if config.voice.isEmpty { config.voice = "CwhRBWXzGAHq8TQ4Fs17" }
        guard !config.apiKey.isEmpty else {
            FileHandle.standardError.write("tts error: no key (set DEMOTAPE_ELEVEN_KEY, or DEMOTAPE_TTS_PROVIDER=OpenAI-compatible for a local server)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    do {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let mp3 = try Voiceover().synthesize(text: script, config: config)
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.moveItem(at: mp3, to: outURL)
        print("tts: \(outURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("tts error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless voice list:  DemoTape --voices   (uses DEMOTAPE_ELEVEN_KEY)
if args.contains("--voices") {
    let key = ProcessInfo.processInfo.environment["DEMOTAPE_ELEVEN_KEY"]
        ?? Keychain.get(account: Keychain.elevenAPIKeyAccount) ?? ""
    guard !key.isEmpty else {
        FileHandle.standardError.write("voices error: no key (set DEMOTAPE_ELEVEN_KEY)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        let voices = try Voiceover().fetchVoices(apiKey: key)
        for v in voices { print("\(v.id)\t\(v.label)") }
        exit(0)
    } catch {
        FileHandle.standardError.write("voices error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless voiceover:  DemoTape --voiceover <video> <script.txt> [voiceId]
// Uses DEMOTAPE_ELEVEN_KEY; writes <name>.voiceover.mp4 next to the video.
if let i = args.firstIndex(of: "--voiceover"), args.count > i + 2 {
    let video = URL(fileURLWithPath: args[i + 1])
    let scriptURL = URL(fileURLWithPath: args[i + 2])
    let env = ProcessInfo.processInfo.environment
    let key = env["DEMOTAPE_ELEVEN_KEY"] ?? Keychain.get(account: Keychain.elevenAPIKeyAccount) ?? ""
    guard !key.isEmpty else {
        FileHandle.standardError.write("voiceover error: no key (set DEMOTAPE_ELEVEN_KEY)\n".data(using: .utf8)!)
        exit(1)
    }
    let voiceId = args.count > i + 3 ? args[i + 3] : (env["DEMOTAPE_ELEVEN_VOICE"] ?? "CwhRBWXzGAHq8TQ4Fs17")
    let model = env["DEMOTAPE_ELEVEN_MODEL"] ?? "eleven_multilingual_v2"
    do {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let result = try Voiceover().generate(video: video, script: script,
                                              voiceId: voiceId, model: model, apiKey: key)
        print("voiceover: \(result.videoURL.path)\nnarration: \(result.narrationAudioURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("voiceover error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless caption burn:  DemoTape --burn <video>
// Loads cues from the cached transcript (or a .srt sidecar) and writes <name>.captioned.mp4.
if let i = args.firstIndex(of: "--burn"), args.count > i + 1 {
    let video = URL(fileURLWithPath: args[i + 1])
    guard let cues = Captions.loadTranscript(for: video), !cues.isEmpty else {
        FileHandle.standardError.write("burn error: no transcript/.srt found for \(video.lastPathComponent)\n".data(using: .utf8)!)
        exit(1)
    }
    let out = video.deletingPathExtension().deletingPathExtension().appendingPathExtension("captioned.mp4")
    let styleID = args.count > i + 2 ? args[i + 2] : "clean"
    let style = CaptionStyle.byID(styleID)
    do {
        try CaptionBurner().burn(video: video, cues: cues, style: style, to: out)
        print("burned: \(out.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("burn error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless tighten:  DemoTape --tighten <video> [speed] [removeSilence 0|1]
// Writes <name>.tight.mp4 (local; no network).
if let i = args.firstIndex(of: "--tighten"), args.count > i + 1 {
    let video = URL(fileURLWithPath: args[i + 1])
    var opts = Tightener.Options()
    if args.count > i + 2, let s = Double(args[i + 2]) { opts.speed = s }
    if args.count > i + 3 { opts.removeSilence = (args[i + 3] != "0") }
    let out = video.deletingPathExtension().deletingPathExtension().appendingPathExtension("tight.mp4")
    do {
        let s = try Tightener().tighten(video: video, options: opts, to: out)
        print(String(format: "tightened: %@  (%.1fs -> %.1fs, %d cuts)",
                     out.path, s.originalDuration, s.outputDuration, s.cuts))
        exit(0)
    } catch {
        FileHandle.standardError.write("tighten error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Headless GIF export:  DemoTape --gif <input> <maxWidth> <fps> <output.gif>
if let i = args.firstIndex(of: "--gif"), args.count > i + 4 {
    let input = URL(fileURLWithPath: args[i + 1])
    let width = Int(args[i + 2]) ?? 640
    let fps = Double(args[i + 3]) ?? 12
    let out = URL(fileURLWithPath: args[i + 4])
    do {
        try GifEncoder().encode(video: input, to: out, maxWidth: width, fps: fps)
        print("gif: \(out.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("gif error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}



// Headless transcode test:  DemoTape --transcode <input> <height> <output.mp4>
if let i = args.firstIndex(of: "--transcode"), args.count > i + 3 {
    let input = URL(fileURLWithPath: args[i + 1])
    let height = Int(args[i + 2]) ?? 540
    let out = URL(fileURLWithPath: args[i + 3])
    do {
        try Transcoder().transcode(input: input, to: out, height: height)
        print("transcoded: \(out.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("transcode error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
// Run as a menu-bar-only accessory app (no Dock icon, no main window).
app.setActivationPolicy(.accessory)

if #available(macOS 12.3, *) {
    let delegate = AppDelegate()
    app.delegate = delegate // NSApplication holds delegate weakly; keep strong ref alive.
    app.run()
} else {
    let alert = NSAlert()
    alert.messageText = "DemoTape"
    alert.informativeText = "DemoTape requires macOS 12.3 or later for screen capture."
    alert.runModal()
}
