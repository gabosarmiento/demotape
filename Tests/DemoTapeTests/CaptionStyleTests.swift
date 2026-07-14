import XCTest
import AppKit
@testable import DemoTape

final class CaptionStyleTests: XCTestCase {

    // MARK: - Catalog

    func testCatalogHasEightStylesFourAnimated() {
        XCTAssertEqual(CaptionStyle.all.count, 8)
        XCTAssertEqual(CaptionStyle.all.filter { $0.animated }.count, 4)
        XCTAssertEqual(CaptionStyle.all.filter { !$0.animated }.count, 4)
    }

    func testCatalogIDsAreUnique() {
        let ids = CaptionStyle.all.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testByIDReturnsMatchOrCleanFallback() {
        XCTAssertEqual(CaptionStyle.byID("karaoke").id, "karaoke")
        XCTAssertEqual(CaptionStyle.byID("does-not-exist").id, "clean")
    }

    // MARK: - Mobile word wrapping

    func testMobileAspectTightensWordsPerLine() {
        for style in CaptionStyle.all {
            // Square / portrait (aspect <= 1.05) → at most 2 words per line.
            XCTAssertLessThanOrEqual(style.maxWordsPerLine(forAspect: 1.0), 2, style.id)
            XCTAssertLessThanOrEqual(style.maxWordsPerLine(forAspect: 0.5625), 2, style.id) // 9:16
        }
    }

    func testWideAspectKeepsBaseWordsPerLine() {
        let s = CaptionStyle.clean
        XCTAssertEqual(s.maxWordsPerLine(forAspect: 16.0 / 9.0), s.baseMaxWordsPerLine)
    }

    func testMobileNeverGoesBelowOne() {
        for style in CaptionStyle.all {
            XCTAssertGreaterThanOrEqual(style.maxWordsPerLine(forAspect: 1.0), 1, style.id)
        }
    }

    // MARK: - Hex color parsing

    func testHexParsesRRGGBB() {
        let c = NSColor(hex: "#FF8000")?.usingColorSpace(.sRGB)
        XCTAssertEqual(c?.redComponent ?? -1, 1.0, accuracy: 0.01)
        XCTAssertEqual(c?.greenComponent ?? -1, 0.5, accuracy: 0.01)
        XCTAssertEqual(c?.blueComponent ?? -1, 0.0, accuracy: 0.01)
    }

    func testHexParsesAlpha() {
        let c = NSColor(hex: "#00000080")
        XCTAssertEqual(c?.alphaComponent ?? -1, 0.5, accuracy: 0.01)
    }

    func testHexRejectsGarbage() {
        XCTAssertNil(NSColor(hex: "#ZZZ"))
        XCTAssertNil(NSColor(hex: "#12"))
    }

    // MARK: - Preview image

    func testPreviewImageHasRequestedSize() {
        let size = CGSize(width: 150, height: 78)
        for style in CaptionStyle.all {
            let img = style.previewImage(size: size)
            XCTAssertEqual(img.size.width, size.width, accuracy: 0.5, style.id)
            XCTAssertEqual(img.size.height, size.height, accuracy: 0.5, style.id)
        }
    }
}
