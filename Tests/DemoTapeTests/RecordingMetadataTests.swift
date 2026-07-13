import XCTest
@testable import DemoTape

final class RecordingMetadataTests: XCTestCase {

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testRoundTripPreservesEvents() throws {
        let meta = RecordingMetadata(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 12.5,
            capturedKeystrokes: true,
            cameraStartOffset: 0.35,
            eventTimeOffset: 0.05,
            display: DisplayInfo(pointWidth: 1440, pointHeight: 900,
                                 pixelWidth: 2880, pixelHeight: 1800, scale: 2),
            cursor: [CursorSample(t: 0, x: 0.1, y: 0.2), CursorSample(t: 1, x: 0.3, y: 0.4)],
            clicks: [ClickSample(t: 0.5, x: 0.5, y: 0.5, button: "left")],
            scrolls: [ScrollSample(t: 0.8, x: 0.5, y: 0.5, dx: 0, dy: -3)],
            keys: [KeySample(t: 0.9, keyCode: 8, chars: "c", modifiers: ["cmd"])])

        let data = try encoder().encode(meta)
        let decoded = try decoder().decode(RecordingMetadata.self, from: data)

        XCTAssertEqual(decoded.duration, 12.5)
        XCTAssertEqual(decoded.capturedKeystrokes, true)
        XCTAssertEqual(decoded.cameraStartOffset, 0.35)
        XCTAssertEqual(decoded.eventTimeOffset, 0.05)
        XCTAssertEqual(decoded.cursor.count, 2)
        XCTAssertEqual(decoded.cursor[1].x, 0.3)
        XCTAssertEqual(decoded.clicks.first?.button, "left")
        XCTAssertEqual(decoded.scrolls.first?.dy, -3)
        XCTAssertEqual(decoded.keys.first?.modifiers, ["cmd"])
        XCTAssertEqual(decoded.startedAt, meta.startedAt)
    }

    func testOlderSidecarWithoutOptionalKeysStillDecodes() throws {
        // cameraStartOffset / eventTimeOffset were added later; old files omit them.
        let json = """
        {
          "version": 1,
          "startedAt": "2023-11-14T22:13:20Z",
          "duration": 5.0,
          "capturedKeystrokes": false,
          "display": {"pointWidth":1280,"pointHeight":800,"pixelWidth":2560,"pixelHeight":1600,"scale":2},
          "cursor": [],
          "clicks": [],
          "scrolls": [],
          "keys": []
        }
        """.data(using: .utf8)!

        let decoded = try decoder().decode(RecordingMetadata.self, from: json)
        XCTAssertNil(decoded.cameraStartOffset)
        XCTAssertNil(decoded.eventTimeOffset)
        XCTAssertEqual(decoded.duration, 5.0)
        XCTAssertEqual(decoded.display.pointWidth, 1280)
    }

    func testDefaultVersionIsSet() {
        let meta = RecordingMetadata(
            startedAt: Date(), duration: 0, capturedKeystrokes: false,
            cameraStartOffset: nil, eventTimeOffset: nil,
            display: DisplayInfo(pointWidth: 0, pointHeight: 0, pixelWidth: 0, pixelHeight: 0, scale: 1),
            cursor: [], clicks: [], scrolls: [], keys: [])
        XCTAssertEqual(meta.version, 1)
    }
}
