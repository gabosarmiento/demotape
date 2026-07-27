import XCTest
import AppKit
@testable import DemoTape

final class CaptionStyleTests: XCTestCase {

    // MARK: - Catalog

    /// Asserts the shape of the catalog, not its exact size — a count breaks every time a style is
    /// added, which says nothing about whether the catalog is any good.
    func testCatalogOffersBothAnimatedAndStaticStyles() {
        XCTAssertGreaterThanOrEqual(CaptionStyle.all.count, 8)
        XCTAssertGreaterThanOrEqual(CaptionStyle.all.filter { $0.animated }.count, 4)
        XCTAssertGreaterThanOrEqual(CaptionStyle.all.filter { !$0.animated }.count, 4)
        // Every style needs a name to show on its card and a usable font size multiplier.
        for style in CaptionStyle.all {
            XCTAssertFalse(style.name.isEmpty, style.id)
            XCTAssertGreaterThan(style.fontScale, 0, style.id)
        }
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

// MARK: - Word-by-word styles
//
// The social-video look: a word or two on screen at a time, big, low in the frame. The count is the
// whole point, so it is pinned here rather than left to the layout code's discretion.

final class WordByWordCaptionStyleTests: XCTestCase {

    func testWordByWordStylesDeclareTheirWordCount() {
        XCTAssertEqual(CaptionStyle.oneWord.wordsAtATime, 1)
        XCTAssertEqual(CaptionStyle.wordPair.wordsAtATime, 2)
        XCTAssertTrue(CaptionStyle.oneWord.isWordByWord)
        // Phrase styles are unaffected.
        XCTAssertFalse(CaptionStyle.clean.isWordByWord)
        XCTAssertEqual(CaptionStyle.clean.wordsAtATime, 0)
    }

    func testWordByWordStylesAreLargerAndSitLow() {
        for style in [CaptionStyle.oneWord, CaptionStyle.wordPair] {
            XCTAssertGreaterThan(style.fontScale, 1.2, "\(style.id) should be noticeably bigger")
            XCTAssertEqual(style.position, .bottom, "\(style.id) should sit low in the frame")
        }
    }

    func testTrailingCommaIsDroppedOnlyWordByWord() {
        // "PRODUCTION," alone reads as a mistake; in a phrase the comma is doing work.
        XCTAssertEqual(CaptionStyle.displayWord("production,", wordByWord: true), "production")
        XCTAssertEqual(CaptionStyle.displayWord("production,", wordByWord: false), "production,")
        // Sentence-enders carry tone, so they stay.
        XCTAssertEqual(CaptionStyle.displayWord("Refusé.", wordByWord: true), "Refusé.")
        XCTAssertEqual(CaptionStyle.displayWord("really?", wordByWord: true), "really?")
        XCTAssertEqual(CaptionStyle.displayWord("stop!", wordByWord: true), "stop!")
    }

    func testCatalogIDsStayUniqueAndResolvable() {
        let ids = CaptionStyle.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids { XCTAssertEqual(CaptionStyle.byID(id).id, id) }
        XCTAssertEqual(CaptionStyle.byID("nope").id, "clean")   // unknown falls back, never crashes
    }

    func testASingleWordWindowAdvancesWithTime() {
        let words = (0..<4).map { CaptionWord(text: "w\($0)", start: Double($0), end: Double($0) + 1) }
        XCTAssertEqual(CaptionBurner.window(for: 0.5, in: words, size: 1).1.map(\.text), ["w0"])
        XCTAssertEqual(CaptionBurner.window(for: 2.5, in: words, size: 1).1.map(\.text), ["w2"])
        XCTAssertEqual(CaptionBurner.window(for: 3.9, in: words, size: 1).1.map(\.text), ["w3"])
    }
}

// MARK: - Synthesized word timings
//
// Transcripts give per-cue timings, not per-word, so word-by-word styles depend on this estimate. The
// bug it fixes: a cue that runs to the next utterance includes the pause, and spreading words evenly
// across it put the last word on screen seconds after it was spoken.

final class SynthesizedWordTimingTests: XCTestCase {

    func testWordsArePackedAtTheStartOfAnOverlongCue() {
        // "y el CTO lo aprobó." — 19 characters of speech on a 10.8s cue, no readable floor.
        let words = CaptionBurner.synthesizeWords(text: "y el CTO lo aprobó.", start: 0, end: 10.8)
        XCTAssertEqual(words.count, 5)
        // All of it said in roughly the first couple of seconds, not stretched over ten.
        XCTAssertLessThan(words.last!.end, 3.0)
        XCTAssertEqual(words.first!.start, 0, accuracy: 0.001)
    }

    func testWordByWordFloorKeepsShortWordsOnScreenLongEnough() {
        // The bug: without a floor "y" (1 char) shows for 0.07s — two frames — and reads as dropped.
        let floor = CaptionBurner.wordByWordMinSeconds
        let words = CaptionBurner.synthesizeWords(text: "y el CTO lo aprobó.", start: 0, end: 10.8,
                                                  minWordDuration: floor)
        for w in words {
            XCTAssertGreaterThanOrEqual(w.end - w.start, floor - 0.001, "\(w.text) too brief")
        }
        // Still tracks the voice: everything shown in the first few seconds, then the last word lingers
        // through the cue's silent tail (handled by the window fallthrough, not here).
        XCTAssertLessThan(words.last!.start, 3.0)
    }

    func testFloorScalesDownOnlyWhenTheCueIsGenuinelyTooShort() {
        // Five words with a 0.42 floor want 2.1s; a 1s cue can't give it, so they scale to fit.
        let words = CaptionBurner.synthesizeWords(text: "one two three four five", start: 0, end: 1.0,
                                                  minWordDuration: 0.42)
        XCTAssertEqual(words.last!.end, 1.0, accuracy: 0.02)
        XCTAssertEqual(words.first!.start, 0, accuracy: 0.001)
    }

    func testEvenSpreadWhenTheSpeechFillsTheCue() {
        // A short cue for a lot of words: it can only use the time it has.
        let text = "this cue is completely full of spoken words already"
        let words = CaptionBurner.synthesizeWords(text: text, start: 5, end: 8)
        XCTAssertEqual(words.last!.end, 8, accuracy: 0.05)
        XCTAssertEqual(words.first!.start, 5, accuracy: 0.001)
    }

    func testLongerWordsGetLongerOnScreen() {
        let words = CaptionBurner.synthesizeWords(text: "a extraordinarily", start: 0, end: 10)
        let first = words[0].end - words[0].start
        let second = words[1].end - words[1].start
        XCTAssertGreaterThan(second, first * 3, "share should follow word length")
    }

    func testTimingsAreOrderedAndInsideTheCue() {
        let words = CaptionBurner.synthesizeWords(text: "one two three four", start: 2, end: 4)
        for (a, b) in zip(words, words.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start + 0.001)
        }
        XCTAssertGreaterThanOrEqual(words.first!.start, 2)
        XCTAssertLessThanOrEqual(words.last!.end, 4.001)
    }

    func testEmptyTextProducesNoWords() {
        XCTAssertTrue(CaptionBurner.synthesizeWords(text: "   ", start: 0, end: 1).isEmpty)
    }
}
