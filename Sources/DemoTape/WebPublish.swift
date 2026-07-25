import Foundation

/// The Web Publish pipeline: turns one styled recording into a `<name>-web/` folder containing an
/// MP4 per size tier, a poster frame, a responsive `<video>` embed, an optional looping GIF, and a
/// short README explaining what to do with them.
///
/// This lives outside `WebPublishController` on purpose. It used to be a private method on that
/// controller, which meant the only way to run it was by clicking through the GUI — so automation
/// (and this repo's own README assets) had to re-implement the same steps by calling `Transcoder`
/// and `GifEncoder` directly, and could drift from what users actually get. Keeping the pipeline
/// here gives one code path shared by the GUI, the `--publish` CLI hook, and the demo driver.
enum WebPublish {

    /// Video heights offered as tiers, largest first is NOT assumed — callers pass any set.
    static let defaultHeights = [720, 540, 360]

    /// Produces `<name>-web/` next to `source`. Returns the folder, or nil if a tier failed.
    static func export(source: URL, heights: [Int] = defaultHeights,
                       gif: Bool = true, gifWidth: Int = 640, gifFps: Int = 10) -> URL? {
        let folder = outputFolder(for: source)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let t = Transcoder()
        let sorted = heights.sorted()
        for h in sorted {
            do {
                try t.transcode(input: source, to: folder.appendingPathComponent("demo-\(h)p.mp4"), height: h)
            } catch {
                Log.write("WebPublish tier \(h) failed: \(error.localizedDescription)")
                return nil
            }
        }

        // Optional animated GIF.
        var gifMade = false
        if gif {
            do {
                try GifEncoder().encode(video: source, to: folder.appendingPathComponent("demo.gif"),
                                        maxWidth: gifWidth, fps: Double(gifFps))
                gifMade = true
            } catch {
                Log.write("WebPublish GIF failed: \(error.localizedDescription)")
                if sorted.isEmpty { return nil }   // GIF-only export that failed
            }
        }

        // Poster + responsive <video> only when we produced MP4 tiers.
        if !sorted.isEmpty {
            t.savePoster(from: source, to: folder.appendingPathComponent("poster.jpg"),
                         maxHeight: sorted.max() ?? 540)
            let embed = embedHTML(heights: sorted)
            try? embed.write(to: folder.appendingPathComponent("embed.html"), atomically: true, encoding: .utf8)
        }

        var files = sorted.sorted(by: >).map { "demo-\($0)p.mp4" }
        if gifMade { files.append("demo.gif") }
        try? readmeText(files: files).write(to: folder.appendingPathComponent("README.txt"),
                                            atomically: true, encoding: .utf8)
        return folder
    }

    /// `<name>-web/` beside the source, with any `.styled` suffix stripped from the base name.
    static func outputFolder(for source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".styled", with: "")
        return source.deletingLastPathComponent()
            .appendingPathComponent("\(base)-web", isDirectory: true)
    }

    /// Responsive `<video>` snippet: largest tier first, each with a min-width media query so the
    /// browser picks the smallest file that still looks sharp. The last source carries no media
    /// query so it acts as the fallback.
    static func embedHTML(heights: [Int]) -> String {
        let breakpoints: [Int: Int] = [720: 1000, 540: 760, 480: 560, 360: 400]
        let desc = heights.sorted(by: >)
        var sources = ""
        for (i, h) in desc.enumerated() {
            let name = "demo-\(h)p.mp4"
            if i < desc.count - 1, let bp = breakpoints[h] {
                sources += "  <source src=\"\(name)\" type=\"video/mp4\" media=\"(min-width: \(bp)px)\">\n"
            } else {
                sources += "  <source src=\"\(name)\" type=\"video/mp4\">\n"
            }
        }
        return """
        <video controls muted loop playsinline preload="metadata" poster="poster.jpg" width="100%">
        \(sources)</video>
        """
    }

    /// The plain-text guide dropped in the export folder.
    static func readmeText(files: [String]) -> String {
        """
        DemoTape — Web Publish
        =======================
        Files: \(files.joined(separator: ", "))
        MP4: H.264 High + AAC, faststart — lightweight, fast-loading.
        demo.gif: looping, silent — drop into a README with ![](demo.gif).
        poster.jpg / embed.html: thumbnail + responsive <video> snippet for your page.

        Uploading to X / LinkedIn: upload the largest mp4 directly — they re-encode it.
        Hosting on your site: upload all files and use embed.html (serves the right size per screen).
        """
    }
}
