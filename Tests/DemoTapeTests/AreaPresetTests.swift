import XCTest
import AppKit
@testable import DemoTape

final class AreaPresetTests: XCTestCase {

    func testGeneralRowIncludesNewSizes() {
        let shorts = AreaPreset.general.map { $0.short }
        XCTAssertTrue(shorts.contains("4:5"))
        XCTAssertTrue(shorts.contains("5:4"))
        XCTAssertTrue(shorts.contains("16:9"))
        XCTAssertTrue(shorts.contains("9:16"))
        XCTAssertTrue(shorts.contains("1:1"))
        XCTAssertTrue(shorts.contains("Free"))
    }

    func testSocialRowHasTenPlatformPresets() {
        XCTAssertEqual(AreaPreset.social.count, 10)
        XCTAssertTrue(AreaPreset.social.allSatisfy { $0.category == .social })
        let shorts = AreaPreset.social.map { $0.short }
        for s in ["YouTube","Shorts","TikTok","IG Reel","IG Story","IG Post",
                  "LinkedIn","LI Post","FB Video","FB Post"] {
            XCTAssertTrue(shorts.contains(s), "missing \(s)")
        }
    }

    func testAllIsGeneralPlusSocial() {
        XCTAssertEqual(AreaPreset.all.count, AreaPreset.general.count + AreaPreset.social.count)
    }

    func testNamesAreUnique() {
        let names = AreaPreset.all.map { $0.name }
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testNamedRoundTrips() {
        for p in AreaPreset.all {
            XCTAssertEqual(AreaPreset.named(p.name).name, p.name)
        }
    }

    func testNamedFallsBackToFreeform() {
        XCTAssertTrue(AreaPreset.named("nope").isFreeform)
    }

    func testSocialAspectsMapCorrectly() {
        func aspect(_ short: String) -> CGFloat? { AreaPreset.social.first { $0.short == short }?.aspect }
        XCTAssertEqual(aspect("YouTube") ?? 0, 16.0 / 9.0, accuracy: 1e-6)
        XCTAssertEqual(aspect("TikTok") ?? 0, 9.0 / 16.0, accuracy: 1e-6)
        XCTAssertEqual(aspect("IG Post") ?? 0, 1.0, accuracy: 1e-6)
    }

    func testSocialPresetsHaveTint() {
        for p in AreaPreset.social {
            XCTAssertNotNil(p.tintHex, p.short)
        }
    }

    func testFreeformHasNoAspectOrTarget() {
        let free = AreaPreset.named("Freeform")
        XCTAssertNil(free.aspect)
        XCTAssertNil(free.targetSize)
    }

    func testIconRendersAtRequestedBox() {
        let img = AreaPreset.named("YouTube · 16:9 · 1920×1080").icon(box: 40)
        XCTAssertEqual(img.size.width, 40, accuracy: 0.5)
        XCTAssertEqual(img.size.height, 40, accuracy: 0.5)
    }
}
