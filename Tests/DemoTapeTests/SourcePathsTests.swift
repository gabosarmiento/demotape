import XCTest
@testable import DemoTape

final class SourcePathsTests: XCTestCase {

    private let base = "DemoTape 2026-07-14 at 21.52.46"
    private var root: URL { URL(fileURLWithPath: "/tmp/DemoTape/\(base)", isDirectory: true) }

    /// Whether the source is the raw file in `.source/` or a styled final at the root, the layout
    /// must resolve to the same recording root, base, and support locations.
    func testResolvesConsistentlyFromRawOrFinal() {
        let raw = root.appendingPathComponent(".source/\(base).mov")
        let styled = root.appendingPathComponent("\(base).styled.mp4")

        for src in [raw, styled] {
            let p = SourcePaths(source: src)
            XCTAssertEqual(p.recordingRoot.path, root.path, src.lastPathComponent)
            XCTAssertEqual(p.base, base, src.lastPathComponent)
        }
    }

    func testFinishedOutputsGoToRoot() {
        let p = SourcePaths(source: root.appendingPathComponent(".source/\(base).mov"))
        XCTAssertEqual(p.output(suffix: "styled").path, root.appendingPathComponent("\(base).styled.mp4").path)
        XCTAssertEqual(p.templateOutput(id: "keynote").path, root.appendingPathComponent("\(base)-keynote.mp4").path)
    }

    func testSupportGoesToDotSource() {
        let p = SourcePaths(source: root.appendingPathComponent("\(base).styled.mp4"))
        let src = root.appendingPathComponent(".source")
        XCTAssertEqual(p.transcriptURL.path, src.appendingPathComponent("\(base).transcript.json").path)
        XCTAssertEqual(p.srtURL.path, src.appendingPathComponent("\(base).srt").path)
        XCTAssertEqual(p.cameraURL.path, src.appendingPathComponent("\(base).cam.mov").path)
        XCTAssertEqual(p.eventsURL.path, src.appendingPathComponent("\(base).events.json").path)
        XCTAssertEqual(p.rawURL.path, src.appendingPathComponent("\(base).mov").path)
    }

    func testTranscriptPathIsStableAcrossDerivatives() {
        // The transcript cache path must be identical whether keyed off the raw or the styled,
        // otherwise a lookup could miss and re-charge the transcription API.
        let raw = SourcePaths(source: root.appendingPathComponent(".source/\(base).mov")).transcriptURL
        let styled = SourcePaths(source: root.appendingPathComponent("\(base).styled.mp4")).transcriptURL
        XCTAssertEqual(raw.path, styled.path)
    }
}
