import XCTest
@testable import DemoTape

/// Pointer shapes. A real cursor changes shape as it moves — a hand over a link, a text bar over a
/// field — and viewers read that without noticing, so the render follows what was recorded.
final class CursorKindTests: XCTestCase {

    private func metadata(cursor: [CursorSample]) -> RecordingMetadata {
        RecordingMetadata(
            startedAt: Date(), duration: 10, capturedKeystrokes: true,
            cameraStartOffset: nil, eventTimeOffset: nil,
            display: DisplayInfo(pointWidth: 1440, pointHeight: 900,
                                 pixelWidth: 1440, pixelHeight: 900, scale: 1),
            cursor: cursor, clicks: [], scrolls: [], keys: [])
    }

    // MARK: - Decoding

    func testKnownKindsParse() {
        XCTAssertEqual(CursorKind(rawValueOrArrow: "hand"), .hand)
        XCTAssertEqual(CursorKind(rawValueOrArrow: "ibeam"), .ibeam)
        XCTAssertEqual(CursorKind(rawValueOrArrow: "resize"), .resize)
        XCTAssertEqual(CursorKind(rawValueOrArrow: "arrow"), .arrow)
    }

    func testUnknownOrMissingKindFallsBackToArrow() {
        // Sidecars recorded before shapes were captured have no kind, and must still render.
        XCTAssertEqual(CursorKind(rawValueOrArrow: nil), .arrow)
        XCTAssertEqual(CursorKind(rawValueOrArrow: ""), .arrow)
        XCTAssertEqual(CursorKind(rawValueOrArrow: "crosshair-something"), .arrow)
    }

    // MARK: - Lookup over time

    func testKindIsAStepFunctionOfTime() {
        // The shape changes the instant the pointer crosses a control, so the value at t is the last
        // sample at or before t — never an interpolation.
        let tl = FocusTimeline(metadata: metadata(cursor: [
            CursorSample(t: 0.0, x: 0.1, y: 0.1, kind: "arrow"),
            CursorSample(t: 1.0, x: 0.2, y: 0.2, kind: "hand"),
            CursorSample(t: 2.0, x: 0.3, y: 0.3, kind: "ibeam"),
        ]))
        XCTAssertEqual(tl.cursorKind(at: 0.5), .arrow)
        XCTAssertEqual(tl.cursorKind(at: 1.0), .hand)
        XCTAssertEqual(tl.cursorKind(at: 1.9), .hand)
        XCTAssertEqual(tl.cursorKind(at: 2.5), .ibeam)
    }

    func testKindBeforeTheFirstSampleUsesTheFirstOne() {
        let tl = FocusTimeline(metadata: metadata(cursor: [
            CursorSample(t: 1.0, x: 0.2, y: 0.2, kind: "hand"),
        ]))
        XCTAssertEqual(tl.cursorKind(at: 0.0), .hand)
    }

    func testNoCursorSamplesStillRenders() {
        XCTAssertEqual(FocusTimeline(metadata: metadata(cursor: [])).cursorKind(at: 1.0), .arrow)
    }

    func testLegacySidecarWithoutKindsRendersAsArrow() {
        let tl = FocusTimeline(metadata: metadata(cursor: [
            CursorSample(t: 0.0, x: 0.1, y: 0.1, kind: nil),
            CursorSample(t: 1.0, x: 0.2, y: 0.2, kind: nil),
        ]))
        XCTAssertEqual(tl.cursorKind(at: 0.5), .arrow)
        XCTAssertEqual(tl.cursorKind(at: 1.5), .arrow)
    }

    // MARK: - Round trip

    func testKindSurvivesEncodingAndDecoding() throws {
        let original = metadata(cursor: [CursorSample(t: 0.5, x: 0.4, y: 0.6, kind: "hand")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecordingMetadata.self, from: data)
        XCTAssertEqual(decoded.cursor.first?.kind, "hand")
    }

    func testSidecarMissingTheKeyDecodes() throws {
        // Exactly the shape of a sidecar written by an older build.
        let json = """
        {"version":1,"startedAt":"2026-07-25T00:00:00Z","duration":3,"capturedKeystrokes":true,
         "display":{"pointWidth":1440,"pointHeight":900,"pixelWidth":1440,"pixelHeight":900,"scale":1},
         "cursor":[{"t":0.1,"x":0.5,"y":0.5}],"clicks":[],"scrolls":[],"keys":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingMetadata.self, from: Data(json.utf8))
        XCTAssertNil(decoded.cursor.first?.kind)
        XCTAssertEqual(FocusTimeline(metadata: decoded).cursorKind(at: 0.2), .arrow)
    }
}
