import Foundation

/// Lightweight, user-initiated validation of BYO API keys. These calls fire only when the
/// user clicks "Test" in AI Settings — the app makes no background network requests.
enum KeyTester {

    enum Result {
        case ok(String)        // key works
        case invalid(String)   // reached the provider, key rejected
        case failed(String)    // couldn't reach / other error
    }

    /// Validates an OpenAI-compatible speech-to-text key with a cheap `GET {baseURL}/models`.
    /// Custom endpoints that don't implement `/models` are reported as "reachable".
    static func testSTT(baseURL: String, apiKey: String, completion: @escaping (Result) -> Void) {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !apiKey.isEmpty else { return finish(.invalid("Enter a key first."), completion) }
        guard let url = URL(string: base + "/models") else {
            return finish(.failed("Invalid base URL."), completion)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        send(req, completion) { code in
            switch code {
            case 200: return .ok("Key verified.")
            case 401, 403: return .invalid("Key rejected by the provider (\(code)).")
            case 404: return .ok("Server reachable (no /models endpoint).")
            default: return .failed("Unexpected response (HTTP \(code)).")
            }
        }
    }

    /// Validates an ElevenLabs key with `GET /v1/voices` using the `xi-api-key` header.
    static func testElevenLabs(apiKey: String, completion: @escaping (Result) -> Void) {
        guard !apiKey.isEmpty else { return finish(.invalid("Enter a key first."), completion) }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else {
            return finish(.failed("Invalid URL."), completion)
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 15
        send(req, completion) { code in
            switch code {
            case 200: return .ok("Key verified.")
            case 401, 403: return .invalid("Key rejected by ElevenLabs (\(code)).")
            default: return .failed("Unexpected response (HTTP \(code)).")
            }
        }
    }

    // MARK: - Plumbing

    private static func send(_ req: URLRequest, _ completion: @escaping (Result) -> Void,
                             classify: @escaping (Int) -> Result) {
        URLSession.shared.dataTask(with: req) { _, response, error in
            let result: Result
            if let error = error {
                result = .failed(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                result = classify(http.statusCode)
            } else {
                result = .failed("No response.")
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func finish(_ result: Result, _ completion: @escaping (Result) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }
}
