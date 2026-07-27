import AppKit

/// "Create a Demo with AI" — a short, skill-first guide. The real engine is the
/// **record-verified-demo skill**: install it into your coding agent once, then just tell the
/// agent what to demo and it drives DemoTape hands-off. The window walks four steps —
/// understand → install the skill → instruct the agent → watch the result — and keeps a
/// low-key "manual prompt" escape hatch for people who'd rather paste instructions themselves.
@available(macOS 12.3, *)
final class DemoComposerController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private var pathField: NSTextField!

    private let repoURL = "https://github.com/gabosarmiento/demotape"
    private let installCmd = "tools/demo-driver/skill/install.sh"
    private let exampleInstruction = "Record a verified demo of <feature> in this app."

    private let w: CGFloat = 580
    // Room for step 4's wrapped sentence and the footer below it, which the old height clipped.
    private let h: CGFloat = 580

    func show(defaultProjectPath: String = "", onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Create a Demo with AI"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContent(defaultProjectPath: defaultProjectPath)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildContent(defaultProjectPath: String) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let inset: CGFloat = 24
        var y = h - inset

        let title = NSTextField(labelWithString: "Let your coding agent make the demo")
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.frame = NSRect(x: inset, y: y - 24, width: w - 2 * inset, height: 24)
        root.addSubview(title)
        y -= 26
        let subtitle = NSTextField(labelWithString: "Install the skill once, then just tell your agent what to demo. It records, narrates, and verifies — hands-off.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.usesSingleLineMode = false
        subtitle.frame = NSRect(x: inset, y: y - 32, width: w - 2 * inset, height: 32)
        root.addSubview(subtitle)
        y -= 44

        // Step 1 — Install the skill.
        y = step(1, "Install the skill in your coding agent",
                 "Runs from a clone of the DemoTape repo. Adds it to Claude Code (or Kiro with --kiro).",
                 y: y, on: root)
        let cmd = NSTextField(labelWithString: installCmd)
        cmd.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cmd.textColor = .labelColor
        cmd.backgroundColor = .textBackgroundColor
        cmd.drawsBackground = true
        cmd.isBordered = true
        cmd.frame = NSRect(x: inset + 26, y: y - 26, width: w - inset - (inset + 26) - 0, height: 24)
        root.addSubview(cmd)
        y -= 32
        let copyInstall = NSButton(title: "Copy install command", target: self, action: #selector(copyInstall))
        copyInstall.bezelStyle = .rounded; copyInstall.controlSize = .small
        copyInstall.frame = NSRect(x: inset + 26, y: y - 24, width: 180, height: 24)
        root.addSubview(copyInstall)
        let repo = linkButton("Open the repo on GitHub ↗", action: #selector(openRepo))
        repo.frame = NSRect(x: inset + 26 + 190, y: y - 22, width: 220, height: 20)
        root.addSubview(repo)
        y -= 30
        // Show which coding agents this is for, so it's clear the skill + copy-paste are for them.
        addAgentChips(y: y, on: root)
        y -= 30

        // Step 2 — Point it at your project (optional).
        y = step(2, "Point it at your project  (optional)",
                 "So the agent understands your app before demoing it.", y: y, on: root)
        pathField = NSTextField(frame: NSRect(x: inset + 26, y: y - 26, width: w - inset - (inset + 26) - 96, height: 24))
        pathField.placeholderString = "/path/to/your/project"
        pathField.stringValue = defaultProjectPath
        root.addSubview(pathField)
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browse))
        browse.bezelStyle = .rounded; browse.controlSize = .small
        browse.frame = NSRect(x: w - inset - 84, y: y - 26, width: 84, height: 24)
        root.addSubview(browse)
        y -= 40

        // Step 3 — Tell your agent what to demo.
        y = step(3, "Tell your agent what to demo",
                 "In a checkout of your app, just ask:", y: y, on: root)
        let example = NSTextField(labelWithString: "“\(exampleInstruction)”")
        example.font = .systemFont(ofSize: 12, weight: .medium)
        example.frame = NSRect(x: inset + 26, y: y - 24, width: w - inset - (inset + 26) - 0, height: 20)
        root.addSubview(example)
        y -= 30
        let copyExample = NSButton(title: "Copy example instruction", target: self, action: #selector(copyExample))
        copyExample.bezelStyle = .rounded; copyExample.controlSize = .small
        copyExample.frame = NSRect(x: inset + 26, y: y - 24, width: 190, height: 24)
        root.addSubview(copyExample)
        y -= 40

        // Step 4 — Watch the result.
        y = step(4, "Watch the result",
                 "DemoTape records, lays a synced voiceover, and verifies it matches — then hands you the video.",
                 y: y, on: root)

        // Footer: low-key manual fallback + Close.
        let manual = linkButton("Prefer to paste a prompt yourself? Copy a manual prompt", action: #selector(copyManualPrompt))
        manual.frame = NSRect(x: inset, y: 20, width: w - 2 * inset - 100, height: 18)
        root.addSubview(manual)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.frame = NSRect(x: w - inset - 88, y: 14, width: 88, height: 32)
        root.addSubview(close)

        return root
    }

    /// Draws "Works with" + a row of subtle rounded agent-name chips, so it's clear the skill and
    /// the copy-paste are meant for the user's coding agent (Cursor, Claude Code, …).
    private func addAgentChips(y: CGFloat, on view: NSView) {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let prefix = NSTextField(labelWithString: "Works with")
        prefix.font = font
        prefix.textColor = .tertiaryLabelColor
        prefix.frame = NSRect(x: 24 + 22, y: y - 17, width: 62, height: 14)
        view.addSubview(prefix)
        var x: CGFloat = 24 + 22 + 62
        // Each agent's own mark, not just its name: a row of grey text claimed compatibility, the marks
        // show it, and they're recognised before the words are read.
        for agent in AgentBrandIcon.allCases {
            let name = agent.label
            let tw = name.size(withAttributes: [.font: font]).width
            let iconSize: CGFloat = 12
            let cw = tw + iconSize + 22
            if x + cw > w - 20 { break }   // don't overflow the window
            let chip = NSView(frame: NSRect(x: x, y: y - 20, width: cw, height: 20))
            chip.wantsLayer = true
            chip.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
            chip.layer?.cornerRadius = 8
            chip.layer?.cornerCurve = .continuous

            let mark = NSImageView(frame: NSRect(x: 7, y: (20 - iconSize) / 2, width: iconSize, height: iconSize))
            mark.image = agent.image(size: iconSize, color: .secondaryLabelColor)
            mark.contentTintColor = .secondaryLabelColor      // for the symbol-backed fallbacks
            chip.addSubview(mark)

            let label = NSTextField(labelWithString: name)
            label.font = font
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 7 + iconSize + 5, y: 3, width: tw + 2, height: 14)
            chip.addSubview(label)

            view.addSubview(chip)
            x += cw + 6
        }
    }

    /// Draws a numbered step heading (bold number badge + title + detail) and returns the new y.
    private func step(_ n: Int, _ titleText: String, _ detailText: String, y: CGFloat, on view: NSView) -> CGFloat {
        let badge = NSTextField(labelWithString: "\(n)")
        badge.font = .systemFont(ofSize: 13, weight: .bold)
        badge.textColor = .controlAccentColor
        badge.frame = NSRect(x: 24, y: y - 18, width: 20, height: 18)
        view.addSubview(badge)
        let t = NSTextField(labelWithString: titleText)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.frame = NSRect(x: 24 + 22, y: y - 18, width: w - 24 - 22 - 24, height: 18)
        view.addSubview(t)
        // Measure the detail instead of assuming one line: step 4's sentence wraps, and a fixed 18pt
        // box cropped its second line clean off — the last thing the window says, half missing.
        let d = NSTextField(wrappingLabelWithString: detailText)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        let textWidth = w - 24 - 22 - 24
        let needed = ceil(d.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        d.frame = NSRect(x: 24 + 22, y: y - 20 - needed, width: textWidth, height: needed)
        view.addSubview(d)
        return y - 26 - needed
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 11)])
        return b
    }

    // MARK: - Actions

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func copyInstall() {
        copy("\(installCmd)            # Claude Code\n\(installCmd) --kiro     # Kiro (this workspace)")
    }
    @objc private func openRepo() { if let url = URL(string: repoURL) { NSWorkspace.shared.open(url) } }
    @objc private func copyExample() { copy(exampleInstruction) }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField.stringValue = url.path
    }

    /// Manual fallback: a full paste-in prompt for people not using the skill.
    @objc private func copyManualPrompt() {
        let prompt = DemoScript.kiroPrompt(idea: "",
                                           projectPath: pathField.stringValue.trimmingCharacters(in: .whitespaces),
                                           targetSeconds: 60, voiceId: nil)
        copy(prompt)
    }

    @objc private func closeWindow() { window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil; onClose?(); onClose = nil }
}
