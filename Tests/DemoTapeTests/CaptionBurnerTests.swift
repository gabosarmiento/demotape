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

    // MARK: - Width fitting

    // A block that already fits is never touched (and never inflated to fill the frame).
    func testWidthFitLeavesFittingBlockAlone() {
        XCTAssertEqual(CaptionBurner.widthFitScale(blockWidth: 600, frameWidth: 1080), 1)
        XCTAssertEqual(CaptionBurner.widthFitScale(blockWidth: 100, frameWidth: 1080), 1)
    }

    // The regression: a two-word cue drawn wider than a 1080-wide portrait frame was centered at a
    // negative x and clipped off both edges. It must be scaled down instead.
    func testWidthFitShrinksOverflowingBlock() {
        let scale = CaptionBurner.widthFitScale(blockWidth: 1400, frameWidth: 1080)
        XCTAssertLessThan(scale, 1)
        XCTAssertEqual(1400 * scale, 1080 * 0.94, accuracy: 0.001)
    }

    // After fitting, the block fits inside the safe width for any overflow amount.
    func testFittedBlockAlwaysFitsSafeWidth() {
        let frame: CGFloat = 1080
        for blockWidth in stride(from: CGFloat(200), through: 5000, by: 137) {
            let fitted = blockWidth * CaptionBurner.widthFitScale(blockWidth: blockWidth,
                                                                 frameWidth: frame)
            XCTAssertLessThanOrEqual(fitted, frame * 0.94 + 0.001,
                                     "block \(blockWidth) still overflows after fitting")
        }
    }

    // Degenerate geometry must not produce a zero/NaN scale that collapses the caption.
    func testWidthFitIgnoresDegenerateSizes() {
        XCTAssertEqual(CaptionBurner.widthFitScale(blockWidth: 0, frameWidth: 1080), 1)
        XCTAssertEqual(CaptionBurner.widthFitScale(blockWidth: 500, frameWidth: 0), 1)
        XCTAssertEqual(CaptionBurner.widthFitScale(blockWidth: 500, frameWidth: 1080,
                                                   safeFraction: 0), 1)
    }
}
