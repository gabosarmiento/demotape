import XCTest
@testable import DemoTape

final class TightenerTests: XCTestCase {

    private let win = 0.1  // 100ms windows for easy math

    func testNoSilenceKeepsWholeClip() {
        let flags = Array(repeating: true, count: 30)  // 3s all loud
        let keep = Tightener.keepRanges(isLoud: flags, windowDuration: win, duration: 3.0,
                                        minSilence: 0.5, padding: 0.1)
        XCTAssertEqual(keep.count, 1)
        XCTAssertEqual(keep[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(keep[0].end, 3.0, accuracy: 1e-9)
    }

    func testLongSilenceIsCutWithPadding() {
        // 1s loud, 1s silence, 1s loud. minSilence 0.5 -> the middle second is cut,
        // minus 0.1 padding each side -> cut [1.1, 1.9]. Keep [0,1.1] and [1.9,3.0].
        var flags = Array(repeating: true, count: 10)
        flags += Array(repeating: false, count: 10)
        flags += Array(repeating: true, count: 10)
        let keep = Tightener.keepRanges(isLoud: flags, windowDuration: win, duration: 3.0,
                                        minSilence: 0.5, padding: 0.1)
        XCTAssertEqual(keep.count, 2)
        XCTAssertEqual(keep[0].start, 0, accuracy: 1e-6)
        XCTAssertEqual(keep[0].end, 1.1, accuracy: 1e-6)
        XCTAssertEqual(keep[1].start, 1.9, accuracy: 1e-6)
        XCTAssertEqual(keep[1].end, 3.0, accuracy: 1e-6)
    }

    func testShortPauseIsNotCut() {
        // 1s loud, 0.3s silence, 1s loud. minSilence 0.5 -> pause kept (too short).
        var flags = Array(repeating: true, count: 10)
        flags += Array(repeating: false, count: 3)
        flags += Array(repeating: true, count: 10)
        let keep = Tightener.keepRanges(isLoud: flags, windowDuration: win, duration: 2.3,
                                        minSilence: 0.5, padding: 0.1)
        XCTAssertEqual(keep.count, 1)
        XCTAssertEqual(keep[0].end, 2.3, accuracy: 1e-6)
    }

    func testLeadingSilenceTrimmed() {
        // 1s silence then 1s loud -> keep starts near 0.9 (padding kept).
        var flags = Array(repeating: false, count: 10)
        flags += Array(repeating: true, count: 10)
        let keep = Tightener.keepRanges(isLoud: flags, windowDuration: win, duration: 2.0,
                                        minSilence: 0.5, padding: 0.1)
        XCTAssertEqual(keep.count, 1)
        XCTAssertEqual(keep[0].start, 0.9, accuracy: 1e-6)
        XCTAssertEqual(keep[0].end, 2.0, accuracy: 1e-6)
    }

    func testEmptyFlagsKeepsWhole() {
        let keep = Tightener.keepRanges(isLoud: [], windowDuration: win, duration: 5.0,
                                        minSilence: 0.5, padding: 0.1)
        XCTAssertEqual(keep.count, 1)
        XCTAssertEqual(keep[0].end, 5.0, accuracy: 1e-9)
    }

    // MARK: - CLI option parsing

    // The regression: named --speed must change ONLY the speed, leaving pauses intact. This is the
    // case that previously required a bare positional `0` and silently cut silence without it.
    func testNamedSpeedKeepsSilence() {
        let o = Tightener.parseOptions(["--speed", "1.25"])
        XCTAssertEqual(o.speed, 1.25, accuracy: 1e-9)
        XCTAssertFalse(o.removeSilence, "named --speed alone must not remove silence")
    }

    func testNamedRemoveSilenceIsOptIn() {
        let o = Tightener.parseOptions(["--speed", "1.25", "--remove-silence"])
        XCTAssertEqual(o.speed, 1.25, accuracy: 1e-9)
        XCTAssertTrue(o.removeSilence)
    }

    func testNamedKeepSilenceIsExplicitOff() {
        let o = Tightener.parseOptions(["--keep-silence", "--speed", "2"])
        XCTAssertEqual(o.speed, 2, accuracy: 1e-9)
        XCTAssertFalse(o.removeSilence)
    }

    // Legacy positional form is preserved byte-for-byte so existing scripts don't change behavior.
    func testLegacyPositionalDefaultsRemoveSilence() {
        // `--tighten v 1.25` (no third token) keeps the old default: silence IS removed.
        let o = Tightener.parseOptions(["1.25"])
        XCTAssertEqual(o.speed, 1.25, accuracy: 1e-9)
        XCTAssertTrue(o.removeSilence)
    }

    func testLegacyPositionalExplicitZeroKeepsSilence() {
        let o = Tightener.parseOptions(["1.25", "0"])
        XCTAssertEqual(o.speed, 1.25, accuracy: 1e-9)
        XCTAssertFalse(o.removeSilence)
    }

    func testLegacyPositionalExplicitOneRemovesSilence() {
        let o = Tightener.parseOptions(["1.25", "1"])
        XCTAssertTrue(o.removeSilence)
    }

    // No tokens at all → the defaults (speed 1.0, silence removal on).
    func testNoTokensAreDefaults() {
        let o = Tightener.parseOptions([])
        XCTAssertEqual(o.speed, 1.0, accuracy: 1e-9)
        XCTAssertTrue(o.removeSilence)
    }
}
