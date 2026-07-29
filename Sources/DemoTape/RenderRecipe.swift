import Foundation
import CoreImage

/// The **render recipe**: every presentation decision that turned a raw take into the styled video,
/// as a small JSON file saved beside the recording.
///
/// Why this exists. DemoTape deliberately has no timeline editor — you want the finished video, not
/// another editing suite. But "no editor" must not mean "no revisions", so the timeline lives as
/// **data** instead of as a UI. A raw `.mov` plus its `events.json` sidecar is already lossless
/// ground truth (cursor, clicks, scrolls, keys), which means the styled video can always be
/// re-derived. What was missing is the other half of the input: the *style*. It used to come from
/// global `UserDefaults` at render time, with two ad-hoc env overrides, so re-rendering an old take
/// silently applied today's settings and nothing could change one setting without touching global
/// state.
///
/// With a recipe, revision becomes: edit one field, re-render. No re-recording, no scrubbing, and
/// the take is bit-for-bit the same footage — so a cosmetic fix can't accidentally change what the
/// demo claims to do.
///
/// **Every field is optional and means "leave this at its default".** That makes a recipe usable as
/// a patch: `{"maxZoom": 1.4}` is valid and changes exactly one thing. Unknown keys are reported
/// rather than ignored, because a silently dropped setting is the worst outcome — the render looks
/// like it succeeded while doing something else.
struct RenderRecipe: Codable, Equatable {

    /// Bumped only for breaking schema changes; readers should accept older versions.
    var version: Int? = 1

    // Framing (region/window capture only).
    var useBackground: Bool?
    var padding: Double?
    var cornerRadius: Double?
    /// "#RRGGBB" — the gradient behind framed content.
    var bgTop: String?
    var bgBottom: String?
    /// Absolute path to a background image, blurred behind the content.
    var backgroundImage: String?

    // Camera (auto-zoom). A critically damped spring: damping ≈ 2·√stiffness.
    var maxZoom: Double?
    var stiffness: Double?
    var damping: Double?

    // Cursor and input affordances.
    var drawCursor: Bool?
    var cursorScale: Double?
    var cursorSmoothing: Double?
    var showShortcuts: Bool?
    var showClickRipples: Bool?
    var clickRippleDuration: Double?

    // Webcam bubble.
    var webcamOverlay: Bool?
    var webcamDiameterFraction: Double?
    var webcamMirror: Bool?
    var webcamCenterX: Double?
    var webcamCenterY: Double?
    var webcamZoom: Double?

    // Output.
    var outputFPS: Double?
    var volumeGain: Double?
    /// "1080x1350" — exact export size. Omit for the native composed size.
    var exportSize: String?
    /// Vertical/social reframe target ("9:16", "4:5", "1080x1920"). When set, a planned camera frames
    /// the recording for that shape — cropping the sides and filling the height — instead of the
    /// reactive auto-zoom. Omit for a normal landscape render.
    var reframeTarget: String?
    /// Multiplier on the computed fill zoom (1 = crop the sides, keep the full height).
    var reframeZoom: Double?
    /// Draw the camera rect on the LANDSCAPE footage instead of producing the reframed output, to
    /// inspect what the camera is doing.
    var reframeDebug: Bool?

    // Branding watermark (fixed position, does not zoom).
    var brandingImage: String?
    var brandingCenterX: Double?
    var brandingCenterY: Double?
    var brandingWidthFraction: Double?

    // MARK: - Applying

    /// Overlays this recipe onto a style. Only the fields present are touched.
    func apply(to style: inout VideoRenderer.Style) {
        if let v = useBackground { style.useBackground = v }
        if let v = padding { style.padding = CGFloat(v) }
        if let v = cornerRadius { style.cornerRadius = CGFloat(v) }
        if let v = bgTop, let c = Self.color(fromHex: v) { style.bgTop = c }
        if let v = bgBottom, let c = Self.color(fromHex: v) { style.bgBottom = c }
        if let v = backgroundImage {
            style.backgroundImageURL = v.isEmpty ? nil : URL(fileURLWithPath: v)
        }

        if let v = maxZoom { style.maxZoom = CGFloat(v) }
        if let v = stiffness { style.stiffness = CGFloat(v) }
        if let v = damping { style.damping = CGFloat(v) }

        if let v = drawCursor { style.drawCursor = v }
        if let v = cursorScale { style.cursorScale = CGFloat(v) }
        if let v = cursorSmoothing { style.cursorSmoothing = CGFloat(v) }
        if let v = showShortcuts { style.showShortcuts = v }
        if let v = showClickRipples { style.showClickRipples = v }
        if let v = clickRippleDuration { style.clickRippleDuration = v }

        if let v = webcamOverlay { style.webcamOverlay = v }
        if let v = webcamDiameterFraction { style.webcamDiameterFraction = CGFloat(v) }
        if let v = webcamMirror { style.webcamMirror = v }
        if let v = webcamCenterX { style.webcamCenterX = CGFloat(v) }
        if let v = webcamCenterY { style.webcamCenterY = CGFloat(v) }
        if let v = webcamZoom { style.webcamZoom = CGFloat(v) }

        if let v = outputFPS { style.outputFPS = v }
        if let v = volumeGain { style.volumeGain = Float(v) }
        if let v = exportSize { style.exportSize = Self.size(fromString: v) }
        if let v = reframeTarget, let size = ReframeGeometry.targetSize(for: v) {
            var rf = style.reframe ?? VideoRenderer.Style.Reframe(targetSize: size)
            rf.targetSize = size
            style.reframe = rf
        }
        if let v = reframeZoom { style.reframe?.zoomMultiplier = CGFloat(v) }
        if let v = reframeDebug { style.reframe?.debugOverlay = v }

        if let v = brandingImage {
            style.brandingImageURL = v.isEmpty ? nil : URL(fileURLWithPath: v)
        }
        if let v = brandingCenterX { style.brandingCenterX = CGFloat(v) }
        if let v = brandingCenterY { style.brandingCenterY = CGFloat(v) }
        if let v = brandingWidthFraction { style.brandingWidthFraction = CGFloat(v) }
    }

    /// A full snapshot of a style, so a recording ships with the complete recipe that produced it
    /// (and an agent has a valid starting point to edit rather than having to guess field names).
    static func capture(from style: VideoRenderer.Style) -> RenderRecipe {
        RenderRecipe(
            version: 1,
            useBackground: style.useBackground,
            padding: Double(style.padding),
            cornerRadius: Double(style.cornerRadius),
            bgTop: hex(from: style.bgTop),
            bgBottom: hex(from: style.bgBottom),
            backgroundImage: style.backgroundImageURL?.path,
            maxZoom: Double(style.maxZoom),
            stiffness: Double(style.stiffness),
            damping: Double(style.damping),
            drawCursor: style.drawCursor,
            cursorScale: Double(style.cursorScale),
            cursorSmoothing: Double(style.cursorSmoothing),
            showShortcuts: style.showShortcuts,
            showClickRipples: style.showClickRipples,
            clickRippleDuration: style.clickRippleDuration,
            webcamOverlay: style.webcamOverlay,
            webcamDiameterFraction: Double(style.webcamDiameterFraction),
            webcamMirror: style.webcamMirror,
            webcamCenterX: Double(style.webcamCenterX),
            webcamCenterY: Double(style.webcamCenterY),
            webcamZoom: Double(style.webcamZoom),
            outputFPS: style.outputFPS,
            volumeGain: Double(style.volumeGain),
            exportSize: style.exportSize.map { string(from: $0) },
            reframeTarget: style.reframe.map { string(from: $0.targetSize) },
            reframeZoom: style.reframe.map { Double($0.zoomMultiplier) },
            reframeDebug: style.reframe.map { $0.debugOverlay },
            brandingImage: style.brandingImageURL?.path,
            brandingCenterX: Double(style.brandingCenterX),
            brandingCenterY: Double(style.brandingCenterY),
            brandingWidthFraction: Double(style.brandingWidthFraction)
        )
    }

    // MARK: - Value parsing (pure)

    /// "#RRGGBB" or "RRGGBB" → colour. Returns nil for anything malformed, so a typo is reported
    /// instead of silently rendering black.
    static func color(fromHex raw: String) -> CIColor? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return CIColor(red: CGFloat((value >> 16) & 0xFF) / 255.0,
                       green: CGFloat((value >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(value & 0xFF) / 255.0)
    }

    static func hex(from color: CIColor) -> String {
        let clamp = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", clamp(color.red), clamp(color.green), clamp(color.blue))
    }

    /// "1080x1350" → size. Accepts an uppercase X and surrounding spaces.
    static func size(fromString raw: String) -> CGSize? {
        let parts = raw.lowercased().split(separator: "x")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    static func string(from size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    // MARK: - Files

    /// Recipes sit beside the recording as `recipe.json`.
    static let filename = "recipe.json"

    /// Every key the schema understands — used to report unknown keys instead of dropping them.
    static let knownKeys: Set<String> = [
        "version", "useBackground", "padding", "cornerRadius", "bgTop", "bgBottom",
        "backgroundImage", "maxZoom", "stiffness", "damping", "drawCursor", "cursorScale",
        "cursorSmoothing", "showShortcuts", "showClickRipples", "clickRippleDuration",
        "webcamOverlay", "webcamDiameterFraction", "webcamMirror", "webcamCenterX",
        "webcamCenterY", "webcamZoom", "outputFPS", "volumeGain", "exportSize",
        "reframeTarget", "reframeZoom", "reframeDebug",
        "brandingImage", "brandingCenterX", "brandingCenterY", "brandingWidthFraction"
    ]

    /// Keys in `data` the schema doesn't know. A misspelled field would otherwise render "fine"
    /// while ignoring the change the user asked for, which is the most confusing failure available.
    static func unknownKeys(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return [] }
        return dict.keys.filter { !knownKeys.contains($0) }.sorted()
    }

    static func load(from url: URL) throws -> RenderRecipe {
        let data = try Data(contentsOf: url)
        let unknown = unknownKeys(in: data)
        if !unknown.isEmpty {
            FileHandle.standardError.write(
                "recipe warning: ignoring unknown key(s): \(unknown.joined(separator: ", "))\n"
                    .data(using: .utf8)!)
        }
        return try JSONDecoder().decode(RenderRecipe.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
