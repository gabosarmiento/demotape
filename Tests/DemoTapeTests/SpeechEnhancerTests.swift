import XCTest
@testable import DemoTape

final class SpeechEnhancerTests: XCTestCase {

    // With no model bundled (as in the test host), the Core ML enhancer must report unavailable
    // and no-op, so callers fall back to the DSP reducer — the whole feature stays safe.
    func testUnavailableWithoutBundledModel() {
        let enhancer = CoreMLSpeechEnhancer()
        XCTAssertFalse(enhancer.isAvailable)
    }

    func testEnhanceReturnsNilWhenUnavailable() {
        let enhancer = CoreMLSpeechEnhancer()
        guard !enhancer.isAvailable else {
            // A model happens to be bundled in this environment — nothing to assert about nil.
            return
        }
        let x = [Float](repeating: 0.1, count: 4096)
        XCTAssertNil(enhancer.enhanceMono(x, sampleRate: 48000))
    }

    func testReduceThrowsWhenUnavailable() {
        let enhancer = CoreMLSpeechEnhancer()
        guard !enhancer.isAvailable else { return }
        let src = URL(fileURLWithPath: "/tmp/does-not-matter.mov")
        let dst = URL(fileURLWithPath: "/tmp/out.mp4")
        XCTAssertThrowsError(try enhancer.reduce(video: src, to: dst))
    }
}
