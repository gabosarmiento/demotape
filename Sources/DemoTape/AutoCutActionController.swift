import AppKit

/// Focused "Auto Cut and Speed" action: removes silent gaps and/or speeds the clip up
/// (pitch preserved). Local, no network. Built on the shared ActionPreviewController.
@available(macOS 12.3, *)
final class AutoCutActionController: ActionPreviewController {

    private let speeds: [Double] = [1.0, 1.25, 1.5, 2.0]
    private let defaultSpeedIndex = 1          // 1.25×
    private var silenceBox: NSButton!
    private var speedControl: NSSegmentedControl!

    override var actionTitle: String { "Auto Cut and Speed" }
    override var nothingMessage: String { "Nothing to change — this clip has no silent gaps to remove." }

    override func makeControls() -> NSView {
        silenceBox = NSButton(checkboxWithTitle: "Remove silent gaps", target: nil, action: nil)
        silenceBox.state = .on
        silenceBox.font = .systemFont(ofSize: 13)

        let speedLabel = NSTextField(labelWithString: "Speed")
        speedLabel.font = .systemFont(ofSize: 13)

        speedControl = NSSegmentedControl(
            labels: speeds.map { $0 == 1.0 ? "1×" : "\(formatted($0))×" },
            trackingMode: .selectOne, target: nil, action: nil)
        speedControl.selectedSegment = defaultSpeedIndex
        speedControl.controlSize = .large

        let speedRow = NSStackView(views: [speedLabel, speedControl])
        speedRow.orientation = .horizontal
        speedRow.spacing = 10

        let stack = NSStackView(views: [silenceBox, speedRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        return stack
    }

    override func render(progress: @escaping (Double) -> Void) throws -> URL? {
        var opts = Tightener.Options()
        opts.removeSilence = (silenceBox.state == .on)
        opts.speed = speeds[max(0, speedControl.selectedSegment)]
        let out = SourcePaths(source: source).output(suffix: "tight")
        let summary = try Tightener().tighten(video: source, options: opts, to: out)
        // Nothing removed and no speed change → treat as "nothing to do".
        if summary.cuts == 0 && opts.speed == 1.0 {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    private func formatted(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(v)
    }
}
