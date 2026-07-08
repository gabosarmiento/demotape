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
        try VideoRenderer().render(videoURL: videoURL, metadata: metadata, cameraURL: camera, to: outURL)
        print("rendered: \(outURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("render error: \(error)\n".data(using: .utf8)!)
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
