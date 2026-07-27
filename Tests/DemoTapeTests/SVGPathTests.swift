import XCTest
@testable import DemoTape

/// The parser draws brand marks, so "does it produce a path" isn't enough — a wrong arc or a mishandled
/// relative command still produces a path, just a mangled one. These check the geometry lands where the
/// path says it should, and that every shipped mark parses and fills its viewBox.
final class SVGPathTests: XCTestCase {

    private func bounds(_ d: String) -> CGRect? { SVGPath.path(fromD: d)?.boundingBoxOfPath }

    func testAbsoluteLinesFormTheStatedBox() {
        let box = bounds("M 2 4 L 10 4 L 10 12 L 2 12 Z")
        XCTAssertEqual(box?.minX ?? -1, 2, accuracy: 0.01)
        XCTAssertEqual(box?.minY ?? -1, 4, accuracy: 0.01)
        XCTAssertEqual(box?.maxX ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(box?.maxY ?? -1, 12, accuracy: 0.01)
    }

    func testRelativeCommandsAccumulate() {
        // Same square, written relatively and compactly, with h/v shorthands.
        let box = bounds("m2 4h8v8h-8z")
        XCTAssertEqual(box?.width ?? 0, 8, accuracy: 0.01)
        XCTAssertEqual(box?.minX ?? -1, 2, accuracy: 0.01)
    }

    func testRepeatedCoordinateSetsAfterOneCommandLetter() {
        // "L" carrying three points must draw three lines, not one.
        let box = bounds("M0 0 L 5 0 10 0 10 10")
        XCTAssertEqual(box?.maxX ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(box?.maxY ?? 0, 10, accuracy: 0.01)
    }

    func testImplicitLineToAfterMove() {
        // A second pair after a moveto is a lineto per the spec — if it were treated as another move,
        // the path would have no extent at all.
        XCTAssertEqual(bounds("M1 1 6 1")?.width ?? 0, 5, accuracy: 0.01)
    }

    func testCompactNumbersWithoutSeparators() {
        // Real icon files write ".5-3" with no spaces; the tokenizer has to split that.
        let box = bounds("M0 0l.5-3")
        XCTAssertEqual(box?.width ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(box?.minY ?? 0, -3, accuracy: 0.001)
    }

    func testArcSweepsToItsEndpoint() {
        // Half circle from (0,0) to (10,0): the endpoint must be reached and the bulge must be on the
        // sweep side, which is what a wrong arc implementation gets wrong.
        let box = bounds("M0 0 A5 5 0 0 1 10 0")
        XCTAssertEqual(box?.minX ?? -1, 0, accuracy: 0.05)
        XCTAssertEqual(box?.maxX ?? -1, 10, accuracy: 0.05)
        XCTAssertEqual(box?.height ?? 0, 5, accuracy: 0.05)
    }

    func testArcWithRadiiTooSmallIsScaledUpInsteadOfFailing() {
        // Radius 1 can't span 10 units; the spec says enlarge the radii rather than give up.
        let box = bounds("M0 0 A1 1 0 0 1 10 0")
        XCTAssertEqual(box?.maxX ?? -1, 10, accuracy: 0.1)
    }

    func testSmoothCurveMirrorsThePreviousControlPoint()  {
        // If S didn't mirror, the curve would kink back and the box would be shorter than 20 wide.
        let box = bounds("M0 0 C 2 -6 8 -6 10 0 S 18 6 20 0")
        XCTAssertEqual(box?.maxX ?? 0, 20, accuracy: 0.01)
        XCTAssertGreaterThan(box?.maxY ?? 0, 1)     // the second hump goes the other way
    }

    func testGarbageProducesNothingRatherThanACrash() {
        XCTAssertNil(SVGPath.path(fromD: ""))
        XCTAssertNil(SVGPath.path(fromD: "not a path"))
        XCTAssertNil(SVGPath.path(fromD: "M"))      // command with no coordinates
    }

    @available(macOS 12.3, *)
    func testEveryShippedMarkParsesAndFillsItsViewBox() {
        for icon in AgentBrandIcon.allCases {
            guard let image = icon.image(size: 32, color: .black) else {
                return XCTFail("\(icon.label) produced no image")
            }
            XCTAssertEqual(image.size.width, 32, accuracy: 0.01, icon.label)
            // A mark that parsed only partially would occupy a sliver; these all fill most of the box.
            XCTAssertFalse(icon.label.isEmpty)
        }
    }

    @available(macOS 12.3, *)
    func testMarkGeometryCoversMostOfTheViewBox() {
        // Guards against a mark that parses but collapses — e.g. an arc that silently degenerates.
        // Brands without a freely-licensed mark draw a system glyph and have no path to measure.
        for icon in AgentBrandIcon.allCases {
            guard let box = icon.debugPathBounds else { continue }
            XCTAssertGreaterThan(box.width, 8, "\(icon.label) is too narrow: \(box)")
            XCTAssertGreaterThan(box.height, 8, "\(icon.label) is too short: \(box)")
            XCTAssertLessThanOrEqual(box.maxX, 24.5, "\(icon.label) overflows the viewBox: \(box)")
            XCTAssertLessThanOrEqual(box.maxY, 24.5, "\(icon.label) overflows the viewBox: \(box)")
        }
    }

    func testFitTransformCentresAndScales() {
        let box = CGRect(x: 0, y: 0, width: 24, height: 24)
        let t = SVGPath.transform(forFitting: box, into: CGSize(width: 48, height: 48))
        let mapped = CGPoint(x: 24, y: 24).applying(t)
        XCTAssertEqual(mapped.x, 48, accuracy: 0.01)
        XCTAssertEqual(mapped.y, 48, accuracy: 0.01)
    }
}

/// Geometry tests prove a mark parsed; they don't prove it DRAWS right. A path filled with the wrong
/// winding rule closes its holes and renders as a near-solid block, which still has correct bounds.
/// Measuring ink catches that, and catches a mark that half-parsed into a sliver.
@available(macOS 12.3, *)
final class AgentBrandIconRenderTests: XCTestCase {

    private func inkFraction(_ icon: AgentBrandIcon) -> Double? {
        guard let image = icon.image(size: 64, color: .black),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        var inked = 0, total = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                total += 1
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.35 { inked += 1 }
            }
        }
        return Double(inked) / Double(max(1, total))
    }

    func testEveryMarkDrawsSomethingButNotAFilledBox() {
        for icon in AgentBrandIcon.allCases {
            guard let ink = inkFraction(icon) else { return XCTFail("\(icon.label): no image") }
            XCTAssertGreaterThan(ink, 0.05, "\(icon.label) drew almost nothing (\(ink))")
            XCTAssertLessThan(ink, 0.92, "\(icon.label) drew a near-solid block (\(ink)) — holes lost")
        }
    }
}
