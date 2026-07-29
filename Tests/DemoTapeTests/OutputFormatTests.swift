import XCTest
import AppKit
@testable import DemoTape

final class SocialDestinationTests: XCTestCase {

    func testOptionsFilterToTheGivenAspect() {
        let vertical = SocialDestination.options(forAspect: 9.0 / 16.0)
        XCTAssertFalse(vertical.isEmpty)
        XCTAssertTrue(vertical.allSatisfy { abs(($0.aspect ?? 0) - 9.0 / 16.0) < 0.02 })
        // 16:9 platforms must not appear in the vertical list.
        XCTAssertFalse(vertical.contains { $0.short == "YouTube" })
        XCTAssertTrue(vertical.contains { $0.short == "TikTok" })
    }

    func testNilAspectOffersEveryPlatform() {
        XCTAssertEqual(SocialDestination.options(forAspect: nil).count, AreaPreset.social.count)
    }

    func testCompatibilityRespectsAspect() {
        let tiktok = AreaPreset.social.first { $0.short == "TikTok" }!.name
        XCTAssertTrue(SocialDestination.isCompatible(tiktok, aspect: 9.0 / 16.0))
        XCTAssertFalse(SocialDestination.isCompatible(tiktok, aspect: 16.0 / 9.0))
        XCTAssertTrue(SocialDestination.isCompatible(tiktok, aspect: nil))  // no lock → anything goes
    }

    func testDefaultNameIsCompatible() {
        for aspect: CGFloat? in [16.0 / 9.0, 9.0 / 16.0, 1.0, 4.0 / 5.0, nil] {
            let name = SocialDestination.defaultName(forAspect: aspect)
            XCTAssertTrue(SocialDestination.isCompatible(name, aspect: aspect))
        }
    }

    func testSlugIsCleanAndStable() {
        XCTAssertEqual(SocialDestination.slug("TikTok · 9:16 · 1080×1920"), "tiktok")
        XCTAssertEqual(SocialDestination.slug("Instagram Reel · 9:16 · 1080×1920"), "instagram-reel")
        XCTAssertEqual(SocialDestination.slug("YouTube · 16:9 · 1920×1080"), "youtube")
    }
}

final class PlatformFitTests: XCTestCase {

    func testCropWideSourceToVerticalTrimsSides() {
        // 1920x1080 (16:9) cropped to 9:16 keeps full height, narrows width.
        let crop = PlatformFit.cropRect(source: CGSize(width: 1920, height: 1080), targetAspect: 9.0 / 16.0)
        XCTAssertEqual(crop.height, 1080, accuracy: 1)
        XCTAssertEqual(crop.width, 1080 * 9.0 / 16.0, accuracy: 1)   // 607.5 → ~608
        XCTAssertEqual(crop.midX, 960, accuracy: 1)                  // centered
        XCTAssertEqual(crop.minY, 0, accuracy: 1)
    }

    func testCropTallSourceToLandscapeTrimsTopBottom() {
        let crop = PlatformFit.cropRect(source: CGSize(width: 1080, height: 1920), targetAspect: 16.0 / 9.0)
        XCTAssertEqual(crop.width, 1080, accuracy: 1)
        XCTAssertEqual(crop.height, 1080 * 9.0 / 16.0, accuracy: 1)
        XCTAssertEqual(crop.midY, 960, accuracy: 1)
    }

    func testMatchingAspectCropIsWholeFrame() {
        let crop = PlatformFit.cropRect(source: CGSize(width: 1080, height: 1920), targetAspect: 9.0 / 16.0)
        XCTAssertEqual(crop.width, 1080, accuracy: 1)
        XCTAssertEqual(crop.height, 1920, accuracy: 1)
    }

    func testAspectsMatch() {
        XCTAssertTrue(PlatformFit.aspectsMatch(CGSize(width: 1080, height: 1920),
                                               CGSize(width: 540, height: 960)))
        XCTAssertFalse(PlatformFit.aspectsMatch(CGSize(width: 1920, height: 1080),
                                                CGSize(width: 1080, height: 1920)))
    }
}

@available(macOS 12.3, *)
final class CaptionSwatchAspectTests: XCTestCase {

    func testLandscapeSwatchIsWide() {
        let s = CaptionStyleCard.tileSize(forAspect: 16.0 / 9.0)
        XCTAssertGreaterThan(s.width, s.height)
        XCTAssertLessThanOrEqual(s.width, 150)
        XCTAssertLessThanOrEqual(s.height, 110)
    }

    func testPortraitSwatchIsTall() {
        let s = CaptionStyleCard.tileSize(forAspect: 9.0 / 16.0)
        XCTAssertGreaterThan(s.height, s.width)
        XCTAssertLessThanOrEqual(s.height, 110)
    }

    func testSquareSwatchIsSquareWithinBox() {
        let s = CaptionStyleCard.tileSize(forAspect: 1.0)
        XCTAssertEqual(s.width, s.height, accuracy: 1.0)
    }

    func testZeroAspectFallsBackToLandscape() {
        let s = CaptionStyleCard.tileSize(forAspect: 0)
        XCTAssertGreaterThan(s.width, s.height)
    }
}
