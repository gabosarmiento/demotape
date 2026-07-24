import AppKit

/// "Create Demo with AI" — describe the demo, point at a project, pick a length. The recommended
/// path is the **record-verified-demo skill** (see "Use the AI skill instead…"): the agent installs
/// it once and drives the whole thing hands-off. This window remains as a **manual fallback** that
/// emits a precise handoff prompt you can paste into a coding agent (Kiro / Claude Code) that has
/// the codebase; the agent then writes the script, records via the `demotape://` control surface,
/// and lays a voiceover over it. The prompt updates live.
@available(macOS 12.3, *)
final class DemoComposerController: NSObject, NSWindowDelegate, NSTextViewDelegate {

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    private var ideaView: NSTextView!
    private var pathField: NSTextField!
    private var durationPopup: NSPopUpButton!
    private var voiceField: NSTextField!
    private var promptView: NSTextView!

    private let durations: [(String, Int)] = [("30 seconds", 30), ("1 minute", 60),
                                              ("1½ minutes", 90), ("2 minutes", 120)]
    private let w: CGFloat = 640
    private let h: CGFloat = 680

    func show(defaultProjectPath: String = "", onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Create Demo with AI"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContent(defaultProjectPath: defaultProjectPath)
        self.window = window

        updatePrompt()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildContent(defaultProjectPath: String) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let inset: CGFloat = 20
        var y = h - inset

        let title = NSTextField(labelWithString: "Describe the demo you want")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.frame = NSRect(x: inset, y: y - 22, width: w - 2 * inset, height: 22)
        root.addSubview(title)
        y -= 26
        let subtitle = NSTextField(labelWithString: "Best: install the record-verified-demo skill so your agent does it all. This prompt is the manual fallback.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: inset, y: y - 16, width: w - 2 * inset, height: 16)
        root.addSubview(subtitle)
        y -= 26

        // Idea text area.
        let ideaScroll = NSScrollView(frame: NSRect(x: inset, y: y - 96, width: w - 2 * inset, height: 96))
        ideaScroll.hasVerticalScroller = true
        ideaScroll.borderType = .bezelBorder
        ideaView = NSTextView(frame: ideaScroll.bounds)
        ideaView.autoresizingMask = [.width]
        ideaView.font = .systemFont(ofSize: 13)
        ideaView.delegate = self
        ideaView.string = ""
        ideaView.textContainerInset = NSSize(width: 6, height: 6)
        ideaScroll.documentView = ideaView
        root.addSubview(ideaScroll)
        placeholderHint("e.g. Show how the dashboard works — sign in, author a domain in Studio, then open a receipt.",
                        below: ideaScroll, on: root)
        y -= 96 + 22

        // Project folder.
        y = addLabel("Project folder", y: y, on: root)
        pathField = NSTextField(frame: NSRect(x: inset, y: y - 24, width: w - 2 * inset - 92, height: 24))
        pathField.placeholderString = "/path/to/your/project"
        pathField.stringValue = defaultProjectPath
        pathField.target = self
        pathField.action = #selector(fieldChanged)
        root.addSubview(pathField)
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browse))
        browse.bezelStyle = .rounded
        browse.frame = NSRect(x: w - inset - 84, y: y - 26, width: 84, height: 28)
        root.addSubview(browse)
        y -= 40

        // Length + voice on one row.
        y = addLabel("Length", y: y, on: root)
        durationPopup = NSPopUpButton(frame: NSRect(x: inset, y: y - 26, width: 160, height: 26))
        durationPopup.addItems(withTitles: durations.map { $0.0 })
        durationPopup.selectItem(at: 1)   // 1 minute
        durationPopup.target = self
        durationPopup.action = #selector(fieldChanged)
        root.addSubview(durationPopup)

        let voiceLabel = NSTextField(labelWithString: "ElevenLabs voice id (optional)")
        voiceLabel.font = .systemFont(ofSize: 11)
        voiceLabel.textColor = .secondaryLabelColor
        voiceLabel.frame = NSRect(x: inset + 176, y: y - 6, width: 240, height: 16)
        root.addSubview(voiceLabel)
        voiceField = NSTextField(frame: NSRect(x: inset + 176, y: y - 26, width: w - inset - (inset + 176), height: 24))
        voiceField.placeholderString = "leave blank to auto-pick"
        voiceField.target = self
        voiceField.action = #selector(fieldChanged)
        root.addSubview(voiceField)
        y -= 42

        // Prompt preview.
        y = addLabel("Prompt for your coding agent", y: y, on: root)
        let promptScroll = NSScrollView(frame: NSRect(x: inset, y: 64, width: w - 2 * inset, height: y - 70))
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptView = NSTextView(frame: promptScroll.bounds)
        promptView.autoresizingMask = [.width]
        promptView.isEditable = false
        promptView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        promptView.textContainerInset = NSSize(width: 6, height: 6)
        promptScroll.documentView = promptView
        root.addSubview(promptScroll)

        // Footer.
        let copy = NSButton(title: "Copy prompt for Kiro", target: self, action: #selector(copyPrompt))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        copy.frame = NSRect(x: w - inset - 200, y: 18, width: 200, height: 32)
        root.addSubview(copy)
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: w - inset - 200 - 96, y: 18, width: 88, height: 32)
        root.addSubview(close)

        // The recommended, AI-led path: install the skill and let the agent run the whole thing.
        let skillButton = NSButton(title: "Use the AI skill instead…", target: self,
                                   action: #selector(showSkillInstructions))
        skillButton.bezelStyle = .rounded
        skillButton.frame = NSRect(x: inset, y: 18, width: 210, height: 32)
        root.addSubview(skillButton)

        return root
    }

    /// Explains the skill-led approach and copies the one-line install command. This is the model
    /// we recommend over copy-pasting the prompt: the agent installs the skill and drives the demo.
    @objc private func showSkillInstructions() {
        let cmd = "tools/demo-driver/skill/install.sh          # Claude Code\n"
            + "tools/demo-driver/skill/install.sh --kiro   # Kiro (this workspace)"
        let alert = NSAlert()
        alert.messageText = "Record a demo with the AI skill"
        alert.informativeText =
            "From a clone of the DemoTape repo, install the record-verified-demo skill into your "
            + "coding agent:\n\n\(cmd)\n\nThen ask your agent, in a checkout of the app you want to "
            + "demo: “Record a verified demo of <feature>.” It understands the app, records with "
            + "DemoTape, lays a synced voiceover, and verifies the result — hands-off.\n\n"
            + "This window's prompt is the manual fallback if you'd rather paste instructions yourself."
        alert.addButton(withTitle: "Copy install command")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }

    private func addLabel(_ text: String, y: CGFloat, on view: NSView) -> CGFloat {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.frame = NSRect(x: 20, y: y - 18, width: w - 40, height: 16)
        view.addSubview(l)
        return y - 22
    }

    private func placeholderHint(_ text: String, below scroll: NSView, on view: NSView) {
        let hint = NSTextField(labelWithString: text)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: 20, y: scroll.frame.minY - 16, width: w - 40, height: 14)
        view.addSubview(hint)
    }

    // MARK: - Live prompt

    func textDidChange(_ notification: Notification) { updatePrompt() }
    @objc private func fieldChanged() { updatePrompt() }

    private func updatePrompt() {
        let seconds = durations[max(0, durationPopup.indexOfSelectedItem)].1
        let voice = voiceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = DemoScript.kiroPrompt(idea: ideaView.string,
                                           projectPath: pathField.stringValue.trimmingCharacters(in: .whitespaces),
                                           targetSeconds: seconds,
                                           voiceId: voice.isEmpty ? nil : voice)
        promptView.string = prompt
    }

    // MARK: - Actions

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField.stringValue = url.path
        updatePrompt()
    }

    @objc private func copyPrompt() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(promptView.string, forType: .string)
    }

    @objc private func closeWindow() { window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil; onClose?(); onClose = nil }
}
