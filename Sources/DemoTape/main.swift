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
        let out = try Voiceover().generate(video: video, script: script,
                                           voiceId: voiceId, model: model, apiKey: key)
        print("voiceover: \(out.path)")
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
    do {
        try CaptionBurner().burn(video: video, cues: cues, to: out)
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
