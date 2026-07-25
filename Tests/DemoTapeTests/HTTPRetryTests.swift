import XCTest
@testable import DemoTape

/// Retry policy for the opt-in AI calls. Verification makes one request per scene, so a multi-scene
/// demo reliably trips hosted rate limits — and a 429 must not be reported as a failed verification.
final class HTTPRetryTests: XCTestCase {

    // MARK: - Which failures are worth retrying

    func testRateLimitIsRetryable() {
        XCTAssertTrue(HTTPRetry.isRetryable(status: 429))
    }

    func testServerErrorsAreRetryable() {
        for status in [500, 502, 503, 504] {
            XCTAssertTrue(HTTPRetry.isRetryable(status: status), "\(status) should retry")
        }
    }

    func testClientErrorsAreNotRetryable() {
        // A bad key or a malformed body fails identically forever; retrying only wastes the user's
        // time and quota.
        for status in [400, 401, 403, 404, 422] {
            XCTAssertFalse(HTTPRetry.isRetryable(status: status), "\(status) should not retry")
        }
    }

    func testSuccessIsNotRetryable() {
        XCTAssertFalse(HTTPRetry.isRetryable(status: 200))
    }

    // MARK: - Backoff

    func testBackoffGrowsExponentially() {
        let first = HTTPRetry.delay(forAttempt: 1, base: 2, cap: 100, jitter: 0)
        let second = HTTPRetry.delay(forAttempt: 2, base: 2, cap: 100, jitter: 0)
        let third = HTTPRetry.delay(forAttempt: 3, base: 2, cap: 100, jitter: 0)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 4)
        XCTAssertEqual(third, 8)
    }

    func testBackoffIsCappedSoADemoNeverLooksHung() {
        let delay = HTTPRetry.delay(forAttempt: 10, base: 2, cap: 20, jitter: 0)
        XCTAssertEqual(delay, 20)
    }

    func testJitterIsAdded() {
        let delay = HTTPRetry.delay(forAttempt: 1, base: 2, cap: 100, jitter: 0.3)
        XCTAssertEqual(delay, 2.3, accuracy: 0.0001)
    }

    func testProviderRetryAfterWinsOverBackoff() {
        // If the provider says when to come back, respect it rather than guessing.
        let delay = HTTPRetry.delay(forAttempt: 1, retryAfter: 7, base: 2, cap: 100, jitter: 0)
        XCTAssertEqual(delay, 7)
    }

    func testRetryAfterIsStillCapped() {
        let delay = HTTPRetry.delay(forAttempt: 1, retryAfter: 600, base: 2, cap: 20, jitter: 0)
        XCTAssertEqual(delay, 20)
    }

    func testZeroRetryAfterFallsBackToBackoff() {
        let delay = HTTPRetry.delay(forAttempt: 2, retryAfter: 0, base: 2, cap: 100, jitter: 0)
        XCTAssertEqual(delay, 4)
    }

    // MARK: - Retry-After parsing

    func testRetryAfterSeconds() {
        XCTAssertEqual(HTTPRetry.retryAfterSeconds("12"), 12)
        XCTAssertEqual(HTTPRetry.retryAfterSeconds(" 3 "), 3)
    }

    func testRetryAfterHTTPDateIsRelativeToNow() {
        let future = Date().addingTimeInterval(30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let seconds = HTTPRetry.retryAfterSeconds(formatter.string(from: future))
        XCTAssertNotNil(seconds)
        XCTAssertEqual(seconds!, 30, accuracy: 2)
    }

    func testRetryAfterRejectsGarbage() {
        XCTAssertNil(HTTPRetry.retryAfterSeconds(nil))
        XCTAssertNil(HTTPRetry.retryAfterSeconds(""))
        XCTAssertNil(HTTPRetry.retryAfterSeconds("soon"))
    }

    func testNegativeRetryAfterIsClampedToZero() {
        let past = Date().addingTimeInterval(-60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(HTTPRetry.retryAfterSeconds(formatter.string(from: past)), 0)
    }
}
