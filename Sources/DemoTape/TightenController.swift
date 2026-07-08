import AppKit
import AVFoundation

/// Panel for the local "tighten" pass: remove silent gaps and/or speed up (pitch-preserved).
/// Outputs a new `…tight.mp4`. No AI, no network.
@available(macOS 12.3, *)
final class TightenController: NSObject, NSWindowDelegate {

    private let video: URL
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    private var silenceBox: NSButton!
    private var speedPopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var goButton: NSButton!

    private let speeds: [Double] = [1.0, 1.1, 1.25, 1.5]

    init(video: URL) { self.video = video }

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let w: CGFloat = 440, h: CGFloat = 250
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Auto-Cut & Speed Up"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let src = NSTextField(labelWithString: "Source: \(video.lastPathComponent)")
        src.font = .systemFont(ofSize: 11); src.textColor = .secondaryLabelColor
        src.lineBreakMode = .byTruncatingMiddle
        src.frame = NSRect(x: 20, y: h - 40, width: w - 40, height: 16)
        content.addSubview(src)

        silenceBox = NSButton(checkboxWithTitle: "  Remove silent gaps (auto-cut dead time)",
                              target: nil, action: nil)
        silenceBox.state = .on
        silenceBox.frame = NSRect(x: 20, y: h - 82, width: w - 40, height: 22)
        content.addSubview(silenceBox)

        let speedLabel = NSTextField(labelWithString: "Speed")
        speedLabel.font = .systemFont(ofSize: 13)
        speedLabel.frame = NSRect(x: 20, y: h - 122, width: 60, height: 20)
        content.addSubview(speedLabel)
        speedPopup = NSPopUpButton(frame: NSRect(x: 84, y: h - 126, width: 120, height: 26))
        speedPopup.addItems(withTitles: speeds.map { $0 == 1.0 ? "1.0× (none)" : "\($0)×" })
        speedPopup.selectItem(at: 0)
        content.addSubview(speedPopup)

        let note = NSTextField(wrappingLabelWithString:
            "Speeds up playback while keeping the voice natural (pitch preserved). Silence "
            + "removal uses loudness detection — fully local, no network.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: 58, width: w - 40, height: 44)
        content.addSubview(note)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 20, width: 200, height: 18)
        content.addSubview(statusLabel)

        goButton = NSButton(title: "Create", target: self, action: #selector(run))
        goButton.bezelStyle = .rounded; goButton.keyEquivalent = "\r"
        goButton.frame = NSRect(x: w - 130, y: 14, width: 110, height: 32)
        content.addSubview(goButton)

        window.contentView = content
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func run() {
        var opts = Tightener.Options()
        opts.removeSilence = (silenceBox.state == .on)
        opts.speed = speeds[speedPopup.indexOfSelectedItem]
        guard opts.removeSilence || opts.speed != 1.0 else {
            statusLabel.stringValue = "Pick silence removal or a speed."
            statusLabel.textColor = .systemOrange
            return
        }
        let outBase = video.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".styled", with: "")
        let out = video.deletingLastPathComponent().appendingPathComponent("\(outBase).tight.mp4")

        goButton.isEnabled = false
        goButton.title = "Working…"
        statusLabel.stringValue = "Analyzing & rendering…"
        statusLabel.textColor = .secondaryLabelColor

        let video = self.video
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let s = try Tightener().tighten(video: video, options: opts, to: out)
                DispatchQueue.main.async {
                    self?.window?.close()
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                    Log.write(String(format: "Tighten UI: %.1fs -> %.1fs", s.originalDuration, s.outputDuration))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.goButton.isEnabled = true
                    self?.goButton.title = "Create"
                    self?.statusLabel.stringValue = "Failed."
                    self?.statusLabel.textColor = .systemRed
                    let a = NSAlert(); a.messageText = "Couldn't create tightened video"
                    a.informativeText = error.localizedDescription; a.runModal()
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) { window = nil; onClose?(); onClose = nil }
}
