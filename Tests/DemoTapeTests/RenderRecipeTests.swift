import XCTest
@testable import DemoTape

/// The recipe is what makes a styled video reproducible and revisable without a timeline editor, so
/// the parts worth testing are: a partial recipe behaves as a patch, values round-trip, malformed
/// values are rejected rather than coerced, and unknown keys are reported instead of dropped.
final class RenderRecipeTests: XCTestCase {

    private func decode(_ json: String) throws -> RenderRecipe {
        try JSONDecoder().decode(RenderRecipe.self, from: Data(json.utf8))
    }

    // MARK: - Patch semantics

    func testPartialRecipeChangesOnlyTheFieldGiven() throws {
        let recipe = try decode(#"{"maxZoom": 1.4}"#)
        var style = VideoRenderer.Style()
        let defaults = VideoRenderer.Style()
        recipe.apply(to: &style)

        XCTAssertEqual(style.maxZoom, 1.4)
        // Everything else must be untouched — that's what makes a one-line recipe safe.
        XCTAssertEqual(style.stiffness, defaults.stiffness)
        XCTAssertEqual(style.drawCursor, defaults.drawCursor)
        XCTAssertEqual(style.outputFPS, defaults.outputFPS)
        XCTAssertEqual(style.webcamCenterX, defaults.webcamCenterX)
    }

    func testEmptyRecipeIsANoOp() throws {
        var style = VideoRenderer.Style()
        style.maxZoom = 3.0
        try decode("{}").apply(to: &style)
        XCTAssertEqual(style.maxZoom, 3.0)
    }

    func testBooleansCanBeTurnedOff() throws {
        var style = VideoRenderer.Style()
        XCTAssertTrue(style.showShortcuts)
        try decode(#"{"showShortcuts": false, "drawCursor": false}"#).apply(to: &style)
        XCTAssertFalse(style.showShortcuts)
        XCTAssertFalse(style.drawCursor)
    }

    func testEmptyPathClearsAnImage() throws {
        var style = VideoRenderer.Style()
        style.brandingImageURL = URL(fileURLWithPath: "/tmp/logo.png")
        try decode(#"{"brandingImage": ""}"#).apply(to: &style)
        XCTAssertNil(style.brandingImageURL, "an empty path should remove branding, not set /")
    }

    // MARK: - Round trip

    func testCaptureThenApplyReproducesTheStyle() throws {
        var original = VideoRenderer.Style()
        original.maxZoom = 1.8
        original.padding = 64
        original.showClickRipples = false
        original.exportSize = CGSize(width: 1080, height: 1350)
        original.brandingImageURL = URL(fileURLWithPath: "/tmp/logo.png")

        let data = try JSONEncoder().encode(RenderRecipe.capture(from: original))
        var rebuilt = VideoRenderer.Style()
        try JSONDecoder().decode(RenderRecipe.self, from: data).apply(to: &rebuilt)

        XCTAssertEqual(rebuilt.maxZoom, original.maxZoom)
        XCTAssertEqual(rebuilt.padding, original.padding)
        XCTAssertEqual(rebuilt.showClickRipples, original.showClickRipples)
        XCTAssertEqual(rebuilt.exportSize, original.exportSize)
        XCTAssertEqual(rebuilt.brandingImageURL, original.brandingImageURL)
    }

    // MARK: - Colours

    func testHexColourParsesWithAndWithoutHash() {
        for text in ["#3366ff", "3366ff", " #3366FF "] {
            guard let c = RenderRecipe.color(fromHex: text) else {
                return XCTFail("failed to parse \(text)")
            }
            XCTAssertEqual(Double(c.red), 0x33 / 255.0, accuracy: 0.001)
            XCTAssertEqual(Double(c.green), 0x66 / 255.0, accuracy: 0.001)
            XCTAssertEqual(Double(c.blue), 1.0, accuracy: 0.001)
        }
    }

    func testMalformedHexIsRejectedRatherThanRenderingBlack() {
        for bad in ["#fff", "not-a-colour", "", "#gggggg", "#1234567"] {
            XCTAssertNil(RenderRecipe.color(fromHex: bad), "should reject \(bad)")
        }
    }

    func testColourRoundTripsThroughHex() {
        let hex = "#0a1b2c"
        let colour = RenderRecipe.color(fromHex: hex)!
        XCTAssertEqual(RenderRecipe.hex(from: colour), hex)
    }

    func testBadColourLeavesTheDefaultInPlace() throws {
        var style = VideoRenderer.Style()
        let before = style.bgTop
        try decode(#"{"bgTop": "nope"}"#).apply(to: &style)
        XCTAssertEqual(style.bgTop.red, before.red)
    }

    // MARK: - Export size

    func testExportSizeParsing() {
        XCTAssertEqual(RenderRecipe.size(fromString: "1080x1350"), CGSize(width: 1080, height: 1350))
        XCTAssertEqual(RenderRecipe.size(fromString: "1920X1080"), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(RenderRecipe.size(fromString: " 640 x 480 "), CGSize(width: 640, height: 480))
    }

    func testInvalidExportSizeIsRejected() {
        for bad in ["1080", "1080x", "axb", "0x500", "-100x200", ""] {
            XCTAssertNil(RenderRecipe.size(fromString: bad), "should reject \(bad)")
        }
    }

    func testExportSizeRoundTrips() {
        let size = CGSize(width: 1080, height: 1350)
        XCTAssertEqual(RenderRecipe.size(fromString: RenderRecipe.string(from: size)), size)
    }

    // MARK: - Unknown keys

    func testUnknownKeysAreReported() {
        let data = Data(#"{"maxZoom": 2, "maxZoomm": 3, "colour": "red"}"#.utf8)
        XCTAssertEqual(RenderRecipe.unknownKeys(in: data), ["colour", "maxZoomm"])
    }

    func testAllKnownKeysPassTheCheck() throws {
        // A full snapshot must contain no key the schema doesn't recognise, or saved recipes would
        // warn on reload.
        let data = try JSONEncoder().encode(RenderRecipe.capture(from: VideoRenderer.Style()))
        XCTAssertEqual(RenderRecipe.unknownKeys(in: data), [])
    }

    func testKnownKeysCoverEveryEncodedField() throws {
        let data = try JSONEncoder().encode(RenderRecipe.capture(from: VideoRenderer.Style()))
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in dict.keys {
            XCTAssertTrue(RenderRecipe.knownKeys.contains(key), "knownKeys is missing \(key)")
        }
    }
}
