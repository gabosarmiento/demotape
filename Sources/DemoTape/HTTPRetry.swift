import Foundation

/// Retry policy for the opt-in AI calls (vision verification, captions, briefs).
///
/// Why this exists: verification makes one request per scene, so a ten-scene demo fires ten calls
/// back to back and hosted providers answer some of them with **429 Too Many Requests**. Treating
/// that as a hard failure meant a perfectly good take came back "unverified" — the demo was fine,
/// the rate limiter simply hadn't caught its breath. A transient status is not a verdict.
///
/// Retries are deliberately conservative: only on 429 and 5xx (never on 4xx, which means the request
/// itself is wrong and will fail identically forever), with exponential backoff plus jitter, and the
/// provider's own `Retry-After` honoured when present.
enum HTTPRetry {

    /// Statuses worth trying again. 429 is rate limiting; 5xx is the provider having a bad moment.
    static func isRetryable(status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }

    /// Seconds to wait before attempt `attempt` (1-based), honouring `Retry-After` when the provider
    /// sent one. Exponential (base 1.5s, doubling) with jitter so parallel callers don't resynchronise,
    /// capped so a demo never appears to hang.
    static func delay(forAttempt attempt: Int, retryAfter: Double? = nil,
                      base: Double = 1.5, cap: Double = 20.0,
                      jitter: Double = Double.random(in: 0...0.4)) -> Double {
        if let retryAfter = retryAfter, retryAfter > 0 { return min(retryAfter, cap) }
        let exponential = base * pow(2.0, Double(max(0, attempt - 1)))
        return min(exponential, cap) + jitter
    }

    /// Parses a `Retry-After` header. The spec allows either seconds or an HTTP date.
    static func retryAfterSeconds(_ header: String?) -> Double? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Double(header) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    /// Sends a request synchronously, retrying transient failures. Call off the main thread.
    ///
    /// - Parameter attempts: total tries, including the first.
    /// - Returns: the body and response of the last attempt.
    static func send(_ request: URLRequest, attempts: Int = 4,
                     label: String = "request") throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            var respData: Data?, respErr: Error?, http: HTTPURLResponse?
            let sema = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { d, r, e in
                respData = d; respErr = e; http = r as? HTTPURLResponse; sema.signal()
            }.resume()
            sema.wait()

            if let http = http, let data = respData {
                if (200..<300).contains(http.statusCode) { return (data, http) }
                guard isRetryable(status: http.statusCode), attempt < attempts else {
                    return (data, http)   // caller reports the status; not our place to interpret it
                }
                let wait = delay(forAttempt: attempt,
                                 retryAfter: retryAfterSeconds(
                                    http.value(forHTTPHeaderField: "Retry-After")))
                Log.write("\(label): HTTP \(http.statusCode) — retrying in \(String(format: "%.1f", wait))s "
                          + "(attempt \(attempt + 1)/\(attempts))")
                Thread.sleep(forTimeInterval: wait)
                continue
            }

            lastError = respErr
            guard attempt < attempts else { break }
            let wait = delay(forAttempt: attempt)
            Log.write("\(label): \(respErr?.localizedDescription ?? "no response") — retrying in "
                      + "\(String(format: "%.1f", wait))s (attempt \(attempt + 1)/\(attempts))")
            Thread.sleep(forTimeInterval: wait)
        }
        throw AIBrief.BriefError.network(lastError?.localizedDescription ?? "no response")
    }
}
