import AppKit

/// A compact speed picker shared by the teleprompter editor and Auto-Cut: a tick-snapping slider
/// over a tinted "recommended" band, a live numeric readout ("1.2×"), and −/+ steppers for
/// precision. Replaces the old coarse segmented pickers.
///
/// All value changes route through `SpeedScale.snap`, so dragging, stepping, and the readout stay
/// consistent and always land on a clean 0.1.
@available(macOS 12.3, *)
final class SpeedSliderView: NSView {

    private let minValue: Double
    private let maxValue: Double
    private let recommended: ClosedRange<Double>

    private let slider = NSSlider()
    private let readout = NSTextField(labelWithString: "")
    private let minus = NSButton()
    private let plus = NSButton()
    private let bandView = BandView()

    /// Called whenever the value changes (drag, step, or programmatic set via the slider).
    var onChange: ((Double) -> Void)?

    private(set) var value: Double {
        didSet { syncReadout() }
    }

    init(value: Double, min: Double, max: Double, recommended: ClosedRange<Double>) {
        self.minValue = min
        self.maxValue = max
        self.recommended = recommended
        self.value = SpeedScale.snap(value, min: min, max: max)
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A sensible default size so the control never collapses when a caller doesn't pin its width
    /// (the teleprompter lays it out by frame; Auto-Cut pins a width inside a stack — both work).
    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 30) }

    private func build() {
        // NOTE: don't force `translatesAutoresizingMaskIntoConstraints` here — the teleprompter uses
        // this view frame-based, while Auto-Cut puts it in an NSStackView (which sets it false). The
        // internal subview constraints below resolve against `self` either way.

        // Recommended-band tint sits behind the slider track.
        bandView.translatesAutoresizingMaskIntoConstraints = false
        bandView.fraction = (
            lo: (recommended.lowerBound - minValue) / (maxValue - minValue),
            hi: (recommended.upperBound - minValue) / (maxValue - minValue))
        addSubview(bandView)

        slider.minValue = minValue
        slider.maxValue = maxValue
        slider.doubleValue = value
        slider.numberOfTickMarks = SpeedScale.tickCount(min: minValue, max: maxValue)
        slider.allowsTickMarkValuesOnly = true      // free-drag, but always snaps to a 0.1 stop
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)

        configureStepper(minus, symbol: "minus", action: #selector(stepDown))
        configureStepper(plus, symbol: "plus", action: #selector(stepUp))

        readout.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        readout.alignment = .right
        readout.translatesAutoresizingMaskIntoConstraints = false
        readout.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(readout)

        NSLayoutConstraint.activate([
            minus.leadingAnchor.constraint(equalTo: leadingAnchor),
            minus.centerYAnchor.constraint(equalTo: centerYAnchor),
            minus.widthAnchor.constraint(equalToConstant: 26),
            minus.heightAnchor.constraint(equalToConstant: 22),

            slider.leadingAnchor.constraint(equalTo: minus.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),

            plus.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 26),
            plus.heightAnchor.constraint(equalToConstant: 22),

            readout.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 10),
            readout.trailingAnchor.constraint(equalTo: trailingAnchor),
            readout.centerYAnchor.constraint(equalTo: centerYAnchor),
            readout.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),

            bandView.leadingAnchor.constraint(equalTo: slider.leadingAnchor, constant: 3),
            bandView.trailingAnchor.constraint(equalTo: slider.trailingAnchor, constant: -3),
            bandView.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            bandView.heightAnchor.constraint(equalToConstant: 4),
        ])
        syncReadout()
    }

    private func configureStepper(_ b: NSButton, symbol: String, action: Selector) {
        b.bezelStyle = .rounded
        b.setButtonType(.momentaryPushIn)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) {
            b.image = img
        } else {
            b.title = symbol == "minus" ? "−" : "+"
        }
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        addSubview(b)   // must be in the hierarchy before its constraints are activated
    }

    // MARK: - Value changes

    @objc private func sliderMoved() {
        setValue(SpeedScale.snap(slider.doubleValue, min: minValue, max: maxValue))
    }
    @objc private func stepDown() { setValue(SpeedScale.step(value, by: -0.1, min: minValue, max: maxValue)) }
    @objc private func stepUp()   { setValue(SpeedScale.step(value, by:  0.1, min: minValue, max: maxValue)) }

    /// Set the value programmatically or from a control; updates slider, readout, and notifies.
    func setValue(_ v: Double) {
        let snapped = SpeedScale.snap(v, min: minValue, max: maxValue)
        value = snapped
        slider.doubleValue = snapped
        onChange?(snapped)
    }

    private func syncReadout() {
        readout.stringValue = SpeedScale.format(value)
        // De-emphasize when outside the useful band, so the recommended range reads as "home".
        readout.textColor = SpeedScale.isRecommended(value, low: recommended.lowerBound,
                                                      high: recommended.upperBound)
            ? .labelColor : .tertiaryLabelColor
    }

    /// A thin tinted pill marking the recommended sub-range behind the slider track.
    private final class BandView: NSView {
        var fraction: (lo: Double, hi: Double) = (0, 1) { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            let full = bounds
            NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: full, xRadius: 2, yRadius: 2).fill()
            let x = full.minX + full.width * CGFloat(max(0, fraction.lo))
            let w = full.width * CGFloat(min(1, fraction.hi) - max(0, fraction.lo))
            let band = NSRect(x: x, y: full.minY, width: max(0, w), height: full.height)
            guard band.width > 1 else { return }
            // The recommended band carries the logo stripe — a small, on-brand flourish.
            Theme.stripeImage(width: band.width, height: band.height, radius: 2).draw(in: band)
        }
    }
}
