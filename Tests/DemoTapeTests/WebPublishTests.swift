import XCTest
@testable import DemoTape

/// Pure logic of the Web Publish pipeline: the responsive embed snippet, the output folder naming,
/// and the guide text. No encoding, no filesystem, no network.
final class WebPublishTests: XCTestCase {

    // MARK: - Output folder

    func testOutputFolderStripsStyledSuffix() {
        let src = URL(fileURLWithPath: "/tmp/rec/My Demo.styled.mp4")
        XCTAssertEqual(WebPublish.outputFolder(for: src).lastPathComponent, "My Demo-web")
    }

    func testOutputFolderSitsBesideSource() {
        let src = URL(fileURLWithPath: "/tmp/rec/My Demo.styled.mp4")
        let folder = WebPublish.outputFolder(for: src)
        XCTAssertEqual(folder.deletingLastPathComponent().path, "/tmp/rec")
    }

    func testOutputFolderWithoutStyledSuffix() {
        let src = URL(fileURLWithPath: "/tmp/rec/clip.mp4")
        XCTAssertEqual(WebPublish.outputFolder(for: src).lastPathComponent, "clip-web")
    }

    // MARK: - Embed snippet

    func testEmbedListsTiersLargestFirst() {
        let html = WebPublish.embedHTML(heights: [360, 720, 540])
        let order = ["demo-720p.mp4", "demo-540p.mp4", "demo-360p.mp4"].map {
            html.range(of: $0)!.lowerBound
        }
        XCTAssertEqual(order, order.sorted(), "sources must be ordered largest tier first")
    }

    func testEmbedGivesLastTierNoMediaQueryAsFallback() {
        let html = WebPublish.embedHTML(heights: [720, 360])
        // The smallest tier is the fallback, so its <source> line carries no media attribute.
        let fallback = html.split(separator: "\n").first { $0.contains("demo-360p.mp4") }
        XCTAssertNotNil(fallback)
        XCTAssertFalse(fallback!.contains("media="))
        // The larger tier is gated behind a breakpoint.
        let gated = html.split(separator: "\n").first { $0.contains("demo-720p.mp4") }
        XCTAssertTrue(gated!.contains("media=\"(min-width: 1000px)\""))
    }

    func testEmbedSingleTierHasNoMediaQuery() {
        let html = WebPublish.embedHTML(heights: [540])
        XCTAssertTrue(html.contains("demo-540p.mp4"))
        XCTAssertFalse(html.contains("media="))
    }

    func testEmbedIsSelfContainedVideoElement() {
        let html = WebPublish.embedHTML(heights: [540])
        XCTAssertTrue(html.hasPrefix("<video"))
        XCTAssertTrue(html.hasSuffix("</video>"))
        XCTAssertTrue(html.contains("poster=\"poster.jpg\""))
        // Autoplay-friendly, README-friendly defaults.
        for attr in ["controls", "muted", "loop", "playsinline"] {
            XCTAssertTrue(html.contains(attr), "missing \(attr)")
        }
    }

    // MARK: - Guide text

    func testReadmeListsTheFilesProduced() {
        let text = WebPublish.readmeText(files: ["demo-720p.mp4", "demo.gif"])
        XCTAssertTrue(text.contains("demo-720p.mp4, demo.gif"))
    }

    func testDefaultHeightsAreWebSensible() {
        XCTAssertEqual(WebPublish.defaultHeights.sorted(), [360, 540, 720])
    }
}
