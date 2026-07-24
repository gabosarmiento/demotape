import XCTest
@testable import DemoTape

final class AudioDevicesTests: XCTestCase {

    func testLoopbackNamesDetected() {
        XCTAssertTrue(AudioDevices.looksLikeLoopback(name: "BlackHole 2ch"))
        XCTAssertTrue(AudioDevices.looksLikeLoopback(name: "BlackHole 16ch"))
        XCTAssertTrue(AudioDevices.looksLikeLoopback(name: "Loopback Audio"))
        XCTAssertTrue(AudioDevices.looksLikeLoopback(name: "Soundflower (2ch)"))
        XCTAssertTrue(AudioDevices.looksLikeLoopback(name: "DemoTape Aggregate Device"))
        XCTAssertTrue(AudioDevices.looksLikeLoopback(name: "Multi-Output Device"))
    }

    func testRealMicsNotFlaggedAsLoopback() {
        XCTAssertFalse(AudioDevices.looksLikeLoopback(name: "MacBook Pro Microphone"))
        XCTAssertFalse(AudioDevices.looksLikeLoopback(name: "External USB Microphone"))
        XCTAssertFalse(AudioDevices.looksLikeLoopback(name: "AirPods Pro"))
    }

    func testDetectionIsCaseInsensitive() {
        XCTAssertTrue(AudioDevices.looksLikeLoopback(name: "BLACKHOLE 2CH"))
        XCTAssertTrue(AudioDevices.looksLikeLoopback(name: "loopback audio"))
    }
}
