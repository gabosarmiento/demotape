import AppKit

/// Review/edit the transcribed subtitles: one auto-height, wrapping row per cue so you can
/// read and edit the full line. Save rewrites the `.srt` / `.vtt` sidecars (and the cached
/// transcript); "Add to Video" burns the captions into a new `…captioned.mp4`.
@available(macOS 12.3, *)
final class CaptionsEditorController: NSObject, NSWindowDelegate, NSTextViewDelegate {

    private let video: URL
    private var cues: [CaptionCue]
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    private var scroll: NSScrollView!
    private var docView: FlippedView!
    private var labels: [NSTextField] = []
    private var textViews: [NSTextView] = []
    private var statusLabel: NSTextField!
    private var saveButton: NSButton!
    private var burnButton: NSButton!

    private let rowFont = NSFont.systemFont(ofSize: 13)
    private let inset: CGFloat = 6

    init(video: URL, cues: [CaptionCue]) {
        self.video = video
        self.cues = cues
    }

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let w: CGFloat = 600, h: CGFloat = 480
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Captions — \(video.deletingPathExtension().lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 320)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let header = NSTextField(labelWithString:
            "Edit the subtitle text (rows grow to fit). Save writes .srt/.vtt; Add to Video burns them in.")
        header.font = .systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 16, y: h - 34, width: w - 32, height: 18)
        header.autoresizingMask = [.width, .minYMargin]
        content.addSubview(header)

        scroll = NSScrollView(frame: NSRect(x: 12, y: 56, width: w - 24, height: h - 100))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        docView = FlippedView(frame: NSRect(x: 0, y: 0, width: w - 24 - 2, height: 10))
        scroll.documentView = docView
        content.addSubview(scroll)
        buildRows()

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 16, y: 20, width: 200, height: 18)
        statusLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        content.addSubview(statusLabel)

        burnButton = NSButton(title: "Add to Video", target: self, action: #selector(addToVideo))
        burnButton.bezelStyle = .rounded
        burnButton.frame = NSRect(x: w - 260, y: 14, width: 130, height: 32)
        burnButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(burnButton)

        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: w - 120, y: 14, width: 100, height: 32)
        saveButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(saveButton)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: w - 360, y: 14, width: 90, height: 32)
        close.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(close)

        window.contentView = content
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Rows

    private func buildRows() {
        labels.forEach { $0.removeFromSuperview() }
        textViews.forEach { $0.removeFromSuperview() }
        labels.removeAll(); textViews.removeAll()

        for cue in cues {
            let tc = NSTextField(labelWithString: "\(Self.mmss(cue.start)) – \(Self.mmss(cue.end))")
            tc.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tc.textColor = .secondaryLabelColor
            docView.addSubview(tc)
            labels.append(tc)

            let tv = NSTextView(frame: .zero)
            tv.isRichText = false
            tv.font = rowFont
            tv.string = cue.text
            tv.textContainerInset = NSSize(width: inset, height: inset)
            tv.isVerticallyResizable = false
            tv.isHorizontallyResizable = false
            tv.textContainer?.lineFragmentPadding = 0
            tv.textContainer?.widthTracksTextView = true
            tv.drawsBackground = true
            tv.backgroundColor = .textBackgroundColor
            tv.wantsLayer = true
            tv.layer?.borderWidth = 1
            tv.layer?.borderColor = NSColor.separatorColor.cgColor
            tv.layer?.cornerRadius = 4
            tv.delegate = self
            docView.addSubview(tv)
            textViews.append(tv)
        }
        layoutRows()
    }

    private func layoutRows() {
        let width = scroll.contentSize.width
        docView.frame.size.width = width
        let leftPad: CGFloat = 12, labelW: CGFloat = 92, gap: CGFloat = 10
        let textX = leftPad + labelW + 8
        let textW = max(120, width - textX - 12)

        var y: CGFloat = 10
        for i in cues.indices {
            let th = max(30, textHeight(textViews[i].string, width: textW))
            labels[i].frame = NSRect(x: leftPad, y: y + inset, width: labelW, height: 16)
            textViews[i].frame = NSRect(x: textX, y: y, width: textW, height: th)
            textViews[i].textContainer?.containerSize = NSSize(width: textW - inset * 2,
                                                               height: .greatestFiniteMagnitude)
            y += th + gap
        }
        docView.frame.size.height = max(y + 4, scroll.contentSize.height)
    }

    private func textHeight(_ s: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: s.isEmpty ? " " : s, attributes: [.font: rowFont])
        let container = NSTextContainer(size: NSSize(width: width - inset * 2, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let lm = NSLayoutManager()
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: container)
        return ceil(lm.usedRect(for: container).height) + inset * 2
    }

    func textDidChange(_ notification: Notification) { layoutRows() }

    func windowDidResize(_ notification: Notification) { layoutRows() }

    // MARK: - Actions

    private func syncCuesFromFields() {
        for (i, tv) in textViews.enumerated() where i < cues.count {
            cues[i].text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc private func save() {
        syncCuesFromFields()
        let kept = cues.filter { !$0.text.isEmpty }
        let base = video.deletingPathExtension()
        do {
            try Captions.writeSRT(kept, to: base.appendingPathExtension("srt"))
            try Captions.writeVTT(kept, to: base.appendingPathExtension("vtt"))
            Captions.saveTranscript(kept, for: video)   // keep the cache in sync with edits
            window?.close()
            NSWorkspace.shared.activateFileViewerSelecting([base.appendingPathExtension("srt")])
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't save captions"
            a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    @objc private func addToVideo() {
        syncCuesFromFields()
        let kept = cues.filter { !$0.text.isEmpty }
        guard !kept.isEmpty else {
            statusLabel.stringValue = "No caption text to burn."
            statusLabel.textColor = .systemOrange
            return
        }
        Captions.saveTranscript(kept, for: video)  // persist edits before rendering

        let outBase = video.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".styled", with: "")
        let out = video.deletingLastPathComponent().appendingPathComponent("\(outBase).captioned.mp4")

        setBusy(true, status: "Burning captions…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try CaptionBurner().burn(video: self!.video, cues: kept, to: out)
                DispatchQueue.main.async {
                    self?.setBusy(false, status: "Done.")
                    self?.window?.close()
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setBusy(false, status: "Failed.")
                    let a = NSAlert(); a.messageText = "Couldn't add captions to video"
                    a.informativeText = error.localizedDescription; a.runModal()
                }
            }
        }
    }

    private func setBusy(_ busy: Bool, status: String) {
        saveButton.isEnabled = !busy
        burnButton.isEnabled = !busy
        burnButton.title = busy ? "Working…" : "Add to Video"
        statusLabel.stringValue = status
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func closeWindow() { window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil; onClose?(); onClose = nil }

    private static func mmss(_ t: Double) -> String {
        let s = Int(max(0, t).rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Top-left origin so scroll rows lay out from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
