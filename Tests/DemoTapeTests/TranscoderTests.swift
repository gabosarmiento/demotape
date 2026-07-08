import XCTest
@testable import DemoTape

final class TranscoderTests: XCTestCase {

    func testTiersAndBitrateTableAgree() {
        // Every advertised tier must have a bitrate, and vice-versa.
        for tier in Transcoder.tiers {
            XCTAssertNotNil(Transcoder.bitrateKbps[tier], "missing bitrate for \(tier)p")
        }
        XCTAssertEqual(Set(Transcoder.bitrateKbps.keys), Set(Transcoder.tiers))
    }

    func testBitratesAreLightweightAndAscending() {
        let sorted = Transcoder.tiers.sorted()
        var last = 0
        for tier in sorted {
            let kbps = Transcoder.bitrateKbps[tier]!
            XCTAssertGreaterThan(kbps, last, "bitrate should increase with resolution")
            last = kbps
        }
        // Sanity: even 720p stays in the "lightweight web demo" range (< 4 Mbps).
        XCTAssertLessThan(Transcoder.bitrateKbps[720]!, 4000)
    }

    func testEstimatedBytesMatchesBitrateMath() {
        // bytes = duration * (videoKbps + audioKbps) * 1000 / 8
        let duration = 120.0            // 2-minute demo
        let audioKbps = 96
        let bytes = Transcoder.estimatedBytes(duration: duration, height: 540, audioKbps: audioKbps)
        let expected = Int(duration * Double(Transcoder.bitrateKbps[540]! + audioKbps) * 1000 / 8)
        XCTAssertEqual(bytes, expected)
    }

    func testTwoMinuteDemoLandsInTargetSizeRange() {
        // The whole point of the tiers: a 2-min demo should be a light, inline-friendly file.
        let mb = Double(Transcoder.estimatedBytes(duration: 120, height: 540)) / 1_000_000
        XCTAssertGreaterThan(mb, 5)
        XCTAssertLessThan(mb, 40)
    }

    func testUnknownHeightUsesFallbackBitrate() {
        // A height not in the table should still produce a positive estimate (fallback).
        let bytes = Transcoder.estimatedBytes(duration: 60, height: 999)
        XCTAssertGreaterThan(bytes, 0)
    }

    func testEstimateScalesLinearlyWithDuration() {
        let oneMin = Transcoder.estimatedBytes(duration: 60, height: 480)
        let twoMin = Transcoder.estimatedBytes(duration: 120, height: 480)
        XCTAssertEqual(twoMin, oneMin * 2, accuracy: 2)  // within rounding
    }
}
