import XCTest
import AppKit
@testable import DemoTape

/// Regression test for the "Auto-Cut window shows nothing" bug: the speed control must lay out to a
/// visible, non-zero size both when pinned by a width (Auto-Cut, inside a stack) and when given a
/// frame (the teleprompter). An earlier version forced its own constraints and collapsed to zero.
@available(macOS 12.3, *)
final class SpeedSliderViewLayoutTests: XCTestCase {

    func testHasNonZeroIntrinsicSize() {
        let v = SpeedSliderView(value: 1.25, min: 1.0, max: 2.0, recommended: 1.0...1.5)
        XCTAssertGreaterThan(v.intrinsicContentSize.width, 0)
        XCTAssertGreaterThan(v.intrinsicContentSize.height, 0)
    }

    func testLaysOutInsideAStack() {
        // Mirror Auto-Cut: the slider lives in an NSStackView with a pinned width.
        let slider = SpeedSliderView(value: 1.25, min: 1.0, max: 2.0, recommended: 1.0...1.5)
        slider.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let stack = NSStackView(views: [NSTextField(labelWithString: "Speed"), slider])
        stack.orientation = .horizontal
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        host.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(slider.frame.width, 360, accuracy: 1)
        XCTAssertGreaterThan(slider.frame.height, 0)
    }

    func testLaysOutFrameBased() {
        // Mirror the teleprompter: a plain frame, no external constraints.
        let slider = SpeedSliderView(value: 1.0, min: 0.5, max: 2.0, recommended: 0.8...1.5)
        slider.frame = NSRect(x: 0, y: 0, width: 420, height: 30)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 60))
        host.addSubview(slider)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(slider.frame.width, 420, accuracy: 1)
        XCTAssertEqual(slider.frame.height, 30, accuracy: 1)
    }
}
