import AppKit
import ImageIO

/// A small gallery window for choosing the framed-mode background: a grid of thumbnails
/// plus a "Custom Image…" button. Clicking a thumbnail saves the choice immediately.
@available(macOS 12.3, *)
final class BackgroundPickerController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var thumbs: [ThumbView] = []

    private let cols = 5
    private let thumbW: CGFloat = 150, thumbH: CGFloat = 92
    private let gap: CGFloat = 14, pad: CGFloat = 20

    func show() {
        let files = Self.backgroundFiles()
        let rows = max(1, Int(ceil(Double(files.count) / Double(cols))))
        let gridW = CGFloat(cols) * thumbW + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * thumbH + CGFloat(rows - 1) * gap
        let contentW = gridW + pad * 2
        let buttonH: CGFloat = 30
        let contentH = pad + buttonH + 16 + gridH + pad

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Choose Background"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))

        // Grid (top-down).
        let selected = Settings.backgroundFile
        for (i, url) in files.enumerated() {
            let r = i / cols, c = i % cols
            let x = pad + CGFloat(c) * (thumbW + gap)
            let y = contentH - pad - thumbH - CGFloat(r) * (thumbH + gap)
            let thumb = ThumbView(url: url, frame: NSRect(x: x, y: y, width: thumbW, height: thumbH))
            thumb.isSelected = (url.lastPathComponent == selected) || (url.path == selected)
            thumb.onSelect = { [weak self] u in self?.select(name: u.lastPathComponent) }
            content.addSubview(thumb)
            thumbs.append(thumb)
        }

        // Custom image button.
        let custom = NSButton(title: "Custom Image…", target: self, action: #selector(chooseCustom))
        custom.bezelStyle = .rounded
        custom.frame = NSRect(x: pad, y: pad, width: 160, height: buttonH)
        content.addSubview(custom)

        window.contentView = content
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func select(name: String) {
        Settings.backgroundFile = name
        for t in thumbs { t.isSelected = (t.url.lastPathComponent == name) }
    }

    @objc private func chooseCustom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Settings.backgroundFile = url.path // absolute path
            for t in thumbs { t.isSelected = false }
        }
    }

    func windowWillClose(_ notification: Notification) { window = nil; thumbs = [] }

    // MARK: - Files

    static func backgroundFiles() -> [URL] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("background"),
              FileManager.default.fileExists(atPath: dir.path),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// A clickable thumbnail with a selection ring.
private final class ThumbView: NSView {
    let url: URL
    var onSelect: ((URL) -> Void)?
    var isSelected = false { didSet { updateBorder() } }
    private let imageView = NSImageView()

    init(url: URL, frame: NSRect) {
        self.url = url
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 2
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = ThumbView.thumbnail(url: url, maxPixel: 320)
        addSubview(imageView)
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateBorder() {
        layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.white.withAlphaComponent(0.15).cgColor
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onSelect?(url) }

    static func thumbnail(url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
