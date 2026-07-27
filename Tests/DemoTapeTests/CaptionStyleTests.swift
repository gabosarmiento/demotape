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

// MARK: - Normalizing real word timings
//
// Transcripts carry per-word timings, and they can't be animated as-is: Whisper emits zero-duration
// words and sub-frame flashes that render in no frame at all. `normalize` is what stops those drops.

final class WordTimingNormalizeTests: XCTestCase {

    func testZeroDurationWordGetsARealInterval() {
        // "And here's the agent itself." — "agent" arrives as 12.46→12.46 in the real transcript.
        let words = [
            CaptionWord(text: "here's", start: 11.90, end: 12.08),   // 0.18 flash
            CaptionWord(text: "the",    start: 12.08, end: 12.46),
            CaptionWord(text: "agent",  start: 12.46, end: 12.46),   // zero-duration → was dropped
            CaptionWord(text: "itself", start: 12.46, end: 12.98)
        ]
        let out = CaptionBurner.normalize(words, minWordDuration: 0.42, cueStart: 11.9, cueEnd: 20)
        XCTAssertEqual(out.count, 4)
        for w in out {
            XCTAssertGreaterThanOrEqual(w.end - w.start, 0.42 - 1e-6, "\(w.text) still too brief")
        }
        // Strictly increasing, no overlaps — so every word owns a stretch of frames.
        for (a, b) in zip(out, out.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start + 1e-6)
            XCTAssertLessThan(a.start, a.end)
        }
    }

    func testHighlightFloorIsGentleButNonZero() {
        let words = [CaptionWord(text: "a", start: 0, end: 0), CaptionWord(text: "b", start: 0, end: 0.02)]
        let out = CaptionBurner.normalize(words, minWordDuration: CaptionBurner.highlightMinSeconds,
                                          cueStart: 0, cueEnd: 10)
        for w in out { XCTAssertGreaterThanOrEqual(w.end - w.start, CaptionBurner.highlightMinSeconds - 1e-6) }
    }

    func testRunIsScaledToStayInsideTheCue() {
        // Six words, each forced to 0.42 (2.52s) but only a 1s cue — must compress, not overflow.
        let words = (0..<6).map { CaptionWord(text: "w\($0)", start: Double($0) * 0.05, end: Double($0) * 0.05) }
        let out = CaptionBurner.normalize(words, minWordDuration: 0.42, cueStart: 0, cueEnd: 1.0)
        XCTAssertLessThanOrEqual(out.last!.end, 1.0 + 1e-6)
        XCTAssertGreaterThanOrEqual(out.first!.start, 0)
    }

    func testRealOnsetsSurviveWhenTheyAreAlreadySpacedOut() {
        // Well-spaced words shouldn't be shoved around — the highlight should still track the voice.
        let words = [CaptionWord(text: "one", start: 0, end: 1),
                     CaptionWord(text: "two", start: 2, end: 3)]
        let out = CaptionBurner.normalize(words, minWordDuration: 0.42, cueStart: 0, cueEnd: 5)
        XCTAssertEqual(out[0].start, 0, accuracy: 1e-6)
        XCTAssertEqual(out[1].start, 2, accuracy: 1e-6)
    }
}

// MARK: - Transcript cache keying
//
// A transcript's cue times fit one audio timeline. Cosmetic renders share it; timeline-changing ones
// and re-voicings must not — sharing them landed a derivative's captions on the wrong cue times.

final class TranscriptCacheKeyTests: XCTestCase {

    private func key(_ name: String) -> String {
        Captions.transcriptURL(for: URL(fileURLWithPath: "/Movies/\(name)")).lastPathComponent
    }

    func testCosmeticRendersShareOneTranscript() {
        // styled / captioned / avatar are the same timeline as the base recording.
        XCTAssertEqual(key("Demo.styled.mp4"), "Demo.transcript.json")
        XCTAssertEqual(key("Demo.captioned.mp4"), "Demo.transcript.json")
        XCTAssertEqual(key("Demo.avatar.mp4"), "Demo.transcript.json")
    }

    func testTimelineChangingRendersGetTheirOwn() {
        // Sped-up / silence-cut, and re-narrated — different audio timing, different transcript.
        XCTAssertEqual(key("Demo.tight.mp4"), "Demo.tight.transcript.json")
        XCTAssertEqual(key("Demo.voiceover.mp4"), "Demo.voiceover.transcript.json")
    }

    func testTheBugCaseIsNowDistinct() {
        // The exact collision that showed the voiceover's cue times on the sped-up clip.
        XCTAssertNotEqual(key("Demo.es.tight.mp4"), key("Demo.voiceover.es.mp4"))
    }

    func testLanguageVariantsStaySeparate() {
        XCTAssertNotEqual(key("Demo.voiceover.es.mp4"), key("Demo.voiceover.fr.mp4"))
    }
}

// MARK: - Reconciling incomplete word timings
//
// Whisper's word list is sometimes SHORTER than the segment text — it drops the last word or two even
// though they were spoken. Drawing word-by-word from that list loses them. `reconcile` restores them.

final class ReconcileWordsTests: XCTestCase {

    func testDroppedTrailingWordIsRestoredAndTimed() {
        // The real cue 0: text ends "…give it a boundary." but timings stop at "a".
        let timed = [
            CaptionWord(text: "you", start: 3.08, end: 3.20),
            CaptionWord(text: "give", start: 3.20, end: 3.34),
            CaptionWord(text: "it", start: 3.34, end: 3.44),
            CaptionWord(text: "a", start: 3.44, end: 3.98)
        ]
        let cue = CaptionCue(start: 3.0, end: 3.98, text: "you give it a boundary.", words: timed)
        let out = Captions.reconcileCue(cue, nextStart: 5.0)
        XCTAssertEqual(out.words?.count, 5, "the dropped 'boundary.' should be added back")
        XCTAssertEqual(out.words?.last?.text, "boundary.")
        // It gets a real interval, after "a", and the cue is extended to include it.
        let last = out.words!.last!
        XCTAssertGreaterThan(last.end, last.start)
        XCTAssertGreaterThan(out.end, 3.98)
        XCTAssertLessThanOrEqual(out.end, 5.0)          // never past the next cue
    }

    func testCompleteTimingsAreLeftAloneButCueStillCoversThem() {
        let timed = [CaptionWord(text: "one", start: 0, end: 0.5),
                     CaptionWord(text: "two", start: 0.5, end: 1.2)]
        let cue = CaptionCue(start: 0, end: 1.0, text: "one two", words: timed)  // end shorter than words
        let out = Captions.reconcileCue(cue, nextStart: 10)
        XCTAssertEqual(out.words?.count, 2)
        XCTAssertGreaterThanOrEqual(out.end, 1.2)       // extended to cover the last word
    }

    func testTailNeverOverlapsTheNextCue() {
        let timed = [CaptionWord(text: "a", start: 0, end: 0.5)]
        let cue = CaptionCue(start: 0, end: 0.5, text: "a whole lot more words here", words: timed)
        let out = Captions.reconcileCue(cue, nextStart: 1.0)
        XCTAssertLessThanOrEqual(out.end, 1.0)
        XCTAssertEqual(out.words?.last?.text, "here")
    }

    func testNoWordTimingsIsUntouched() {
        let cue = CaptionCue(start: 0, end: 2, text: "plain text", words: nil)
        let out = Captions.reconcileCue(cue, nextStart: 10)
        XCTAssertNil(out.words)                          // synthesis still happens later, in the burner
    }
}
