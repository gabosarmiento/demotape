import AppKit

/// A big, semi-transparent teleprompter that scrolls a script for the presenter to read.
///
/// IMPORTANT: `AVCaptureScreenInput` captures the entire display framebuffer (sharingType has
/// no effect), so anything drawn over the recorded pixels ends up in the video. To stay OUT of
/// the recording, the teleprompter is placed in the empty screen area OUTSIDE the recorded
/// region and clipped to it. It therefore only works with a region recording that leaves some
/// free space — it can't be shown (hidden) during a full-screen capture.
/// Geometry for the full-screen teleprompter strip: given a display size and the chosen edge,
/// returns the recorded crop (bottom-left) and the same area in top-left coords (for events).
enum TeleprompterStrip {
    static func crop(width W: CGFloat, height H: CGFloat, edge: String, fraction: CGFloat)
        -> (crop: CGRect, regionTopLeft: CGRect) {
        let sh = (H * fraction).rounded()
        let sw = (W * fraction).rounded()
        switch edge {
        case "bottom":
            return (CGRect(x: 0, y: sh, width: W, height: H - sh),
                    CGRect(x: 0, y: 0, width: W, height: H - sh))
        case "left":
            return (CGRect(x: sw, y: 0, width: W - sw, height: H),
                    CGRect(x: sw, y: 0, width: W - sw, height: H))
        case "right":
            return (CGRect(x: 0, y: 0, width: W - sw, height: H),
                    CGRect(x: 0, y: 0, width: W - sw, height: H))
        default: // top
            return (CGRect(x: 0, y: 0, width: W, height: H - sh),
                    CGRect(x: 0, y: sh, width: W, height: H - sh))
        }
    }
}

@available(macOS 12.3, *)
final class TeleprompterOverlay {
    private var window: NSWindow?
    private var label: NSTextField?
    private var timer: Timer?
    private var travel: CGFloat = 0
    private var startY: CGFloat = 0
    private var perTick: CGFloat = 0

    /// Shows the teleprompter scrolling within the free area outside `recordedRect` (screen
    /// coords, bottom-left). Pass `nil` for full-screen (returns false — nowhere safe to draw).
    /// Returns whether it was shown.
    @discardableResult
    func show(text: String, minutes: Double, recordedRect: CGRect?, edge: String) -> Bool {
        guard let screen = NSScreen.main,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let rect = recordedRect else { return false }
        // Prefer the margin on the chosen edge; fall back to the largest free margin.
        let band = Self.band(screen: screen.frame, avoiding: rect, edge: edge)
                   ?? Self.largestFreeBand(screen: screen.frame, avoiding: rect)
        guard let band = band, band.width >= 280, band.height >= 70 else { return false }
        return present(text: text, minutes: minutes, band: band, screen: screen.frame)
    }

    /// The free margin on a specific edge around `avoiding`, or nil if it's too small to use.
    static func band(screen: CGRect, avoiding r: CGRect, edge: String) -> CGRect? {
        let b: CGRect
        switch edge {
        case "bottom": b = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: r.minY - screen.minY)
        case "left":   b = CGRect(x: screen.minX, y: screen.minY, width: r.minX - screen.minX, height: screen.height)
        case "right":  b = CGRect(x: r.maxX, y: screen.minY, width: screen.maxX - r.maxX, height: screen.height)
        default:       b = CGRect(x: screen.minX, y: r.maxY, width: screen.width, height: screen.maxY - r.maxY) // top
        }
        return (b.width >= 280 && b.height >= 70) ? b : nil
    }

    /// For the settings "Test": preview the scroll in the strip for the chosen edge (so it looks
    /// exactly like it will during a full-screen recording). Not a recording, so it's safe.
    @discardableResult
    func showPreview(text: String, minutes: Double, edge: String, fraction: CGFloat) -> Bool {
        guard let screen = NSScreen.main,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let f = screen.frame
        let (crop, _) = TeleprompterStrip.crop(width: f.width, height: f.height,
                                               edge: edge, fraction: fraction)
        let recorded = crop.offsetBy(dx: f.minX, dy: f.minY)
        guard let band = Self.largestFreeBand(screen: f, avoiding: recorded) else { return false }
        return present(text: text, minutes: minutes, band: band, screen: f)
    }

    @discardableResult
    private func present(text: String, minutes: Double, band: CGRect, screen: CGRect) -> Bool {
        stop()

        let window = NSWindow(contentRect: screen, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.size))
        content.wantsLayer = true

        // Center a readable column within the band (roughly the settings-window width), rather
        // than spanning the whole strip. Clip to it so text never spills into the recording.
        let bandLocal = CGRect(x: band.minX - screen.minX, y: band.minY - screen.minY,
                               width: band.width, height: band.height)
        let colW = min(bandLocal.width, 620)
        let clip = NSView(frame: CGRect(x: bandLocal.minX + (bandLocal.width - colW) / 2,
                                        y: bandLocal.minY, width: colW, height: bandLocal.height))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        clip.layer?.cornerRadius = 10
        content.addSubview(clip)

        let fontSize: CGFloat = min(46, max(26, min(colW * 0.06, bandLocal.height * 0.42)))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 10
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 6
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.97),
            .paragraphStyle: para, .shadow: shadow
        ])
        let textW = colW - 40
        let height = Self.textHeight(attr, width: textW)
        let label = NSTextField(labelWithAttributedString: attr)
        label.frame = NSRect(x: 20, y: -height, width: textW, height: height)  // clip-local coords
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        clip.addSubview(label)

        window.contentView = content
        window.orderFrontRegardless()
        self.window = window
        self.label = label

        let duration = max(5.0, minutes * 60.0)
        startY = -height
        travel = bandLocal.height + height
        let interval = 1.0 / 30.0
        perTick = travel * CGFloat(interval / duration)
        var y = startY
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, let label = self.label else { return }
            y += self.perTick
            label.setFrameOrigin(NSPoint(x: label.frame.minX, y: y))
            if y >= self.startY + self.travel { self.stop() }
        }
        return true
    }

    func stop() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil); window = nil; label = nil
    }

    var isRunning: Bool { window != nil }

    /// The largest of the four margins (top/bottom/left/right) around `avoiding`.
    static func largestFreeBand(screen: CGRect, avoiding r: CGRect) -> CGRect? {
        let bands = [
            CGRect(x: screen.minX, y: r.maxY, width: screen.width, height: screen.maxY - r.maxY),   // top
            CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: r.minY - screen.minY), // bottom
            CGRect(x: screen.minX, y: screen.minY, width: r.minX - screen.minX, height: screen.height), // left
            CGRect(x: r.maxX, y: screen.minY, width: screen.maxX - r.maxX, height: screen.height)    // right
        ]
        return bands.filter { $0.width > 0 && $0.height > 0 }
                    .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Effective scroll duration (minutes). "fit" uses `fitMinutes`; else scales ~130 wpm by speed.
    static func scrollMinutes(text: String, speed: Double, fit: Bool, fitMinutes: Double) -> Double {
        if fit { return max(0.15, fitMinutes) }
        let words = max(1, text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count)
        let base = Double(words) / 130.0
        return max(0.15, base / max(0.25, speed))
    }

    private static func textHeight(_ attr: NSAttributedString, width: CGFloat) -> CGFloat {
        let box = attr.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(box.height) + 20
    }
}
