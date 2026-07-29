import Foundation

/// Pure logic behind the fine-grained speed controls (teleprompter scroll speed and Auto-Cut
/// playback speed). Kept free of AppKit so it can be unit-tested and reused by both editors.
///
/// The UI is a slider that snaps to 0.1 steps, a numeric readout ("1.2×"), and −/+ steppers. All
/// three funnel through `snap` (to land on a clean tenth) and `format` (to render the readout),
/// so a value typed, dragged, or stepped always looks and behaves the same.
enum SpeedScale {

    /// Round `value` to the nearest `step` (default 0.1) and clamp to `[min, max]`.
    static func snap(_ value: Double, step: Double = 0.1, min lo: Double, max hi: Double) -> Double {
        guard step > 0 else { return Swift.min(Swift.max(value, lo), hi) }
        let snapped = (value / step).rounded() * step
        // Rounding in binary floating point leaves fuzz like 1.2000000000000002; round to the
        // number of decimals the step implies so the readout and the stored value stay clean.
        let decimals = Swift.max(0, -Int(floor(log10(step))))
        let f = pow(10.0, Double(decimals))
        let clean = (snapped * f).rounded() / f
        return Swift.min(Swift.max(clean, lo), hi)
    }

    /// Nudge by one step in either direction (used by the −/+ steppers), snapped and clamped.
    static func step(_ value: Double, by delta: Double, min lo: Double, max hi: Double) -> Double {
        snap(value + delta, step: abs(delta) == 0 ? 0.1 : abs(delta), min: lo, max: hi)
    }

    /// The readout label: whole numbers drop the decimal ("1×", "2×"), everything else shows one
    /// decimal ("0.5×", "1.2×").
    static func format(_ value: Double) -> String {
        let snapped = snap(value, min: 0, max: .greatestFiniteMagnitude)
        if snapped.rounded() == snapped {
            return "\(Int(snapped))×"
        }
        return String(format: "%.1f×", snapped)
    }

    /// Number of discrete 0.1 stops across `[lo, hi]`, for an `NSSlider`'s tick count.
    static func tickCount(min lo: Double, max hi: Double, step: Double = 0.1) -> Int {
        guard step > 0, hi > lo else { return 2 }
        return Int(((hi - lo) / step).rounded()) + 1
    }

    /// Whether `value` sits inside the recommended band (inclusive), used to de-emphasize the
    /// readout when the user strays outside it.
    static func isRecommended(_ value: Double, low: Double, high: Double) -> Bool {
        value >= low - 1e-9 && value <= high + 1e-9
    }
}
