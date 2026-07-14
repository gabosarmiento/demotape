import XCTest
@testable import DemoTape

final class CaptionBurnerTests: XCTestCase {

    private func words(_ n: Int) -> [CaptionWord] {
        (0..<n).map { CaptionWord(text: "w\($0)", start: Double($0), end: Double($0) + 1) }
    }

    // A short cue that fits in one window is returned whole.
    func testWindowSmallerThanSizeReturnsAll() {
        let ws = words(4)
        let (idx, out) = CaptionBurner.window(for: 0.5, in: ws, size: 6)
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(out.count, 4)
    }

    // A long cue is split; early time → first window, never the whole paragraph.
    func testWindowStepsThroughChunks() {
        let ws = words(13)                    // 13 words, size 6 → windows [0..5],[6..11],[12]
        let (i0, w0) = CaptionBurner.window(for: 0.5, in: ws, size: 6)
        XCTAssertEqual(i0, 0)
        XCTAssertEqual(w0.map { $0.text }, ["w0","w1","w2","w3","w4","w5"])

        let (i1, w1) = CaptionBurner.window(for: 7.5, in: ws, size: 6)
        XCTAssertEqual(i1, 1)
        XCTAssertEqual(w1.first?.text, "w6")
        XCTAssertEqual(w1.count, 6)

        let (i2, w2) = CaptionBurner.window(for: 12.5, in: ws, size: 6)
        XCTAssertEqual(i2, 2)
        XCTAssertEqual(w2.map { $0.text }, ["w12"])
    }

    // No window ever exceeds the cap (≤ maxWordsPerLine * maxLines).
    func testNoWindowExceedsSize() {
        let ws = words(20)
        for t in stride(from: 0.0, to: 20.0, by: 0.5) {
            let (_, out) = CaptionBurner.window(for: t, in: ws, size: 4)
            XCTAssertLessThanOrEqual(out.count, 4, "t=\(t)")
            XCTAssertFalse(out.isEmpty, "t=\(t)")
        }
    }

    // Past the end of the last word, clamp to the final window rather than returning empty.
    func testTimeBeyondEndClampsToLastWindow() {
        let ws = words(13)
        let (idx, out) = CaptionBurner.window(for: 999, in: ws, size: 6)
        XCTAssertEqual(idx, 2)
        XCTAssertEqual(out.map { $0.text }, ["w12"])
    }
}
