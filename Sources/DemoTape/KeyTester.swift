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
        guard let url = URL(string: base + "/models") else {
            return finish(.failed("Invalid base URL."), completion)
        }
        // A key is optional against a local server; only require one for a remote endpoint.
        let local = base.contains("localhost") || base.contains("127.0.0.1") || base.contains("0.0.0.0")
        guard !apiKey.isEmpty || local else { return finish(.invalid("Enter a key first."), completion) }
        var req = URLRequest(url: url)
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 15
        send(req, completion) { code in
            switch code {
            case 200: return .ok(apiKey.isEmpty ? "Server reachable." : "Key verified.")
            case 401, 403: return .invalid("Key rejected by the provider (\(code)).")
            case 404: return .ok("Server reachable (no /models endpoint).")
            default: return .failed("Unexpected response (HTTP \(code)).")
            }
        }
    }

    /// Validates a HeyGen key with the lightweight `GET /v1/user/me` (tiny response, unlike the
    /// large `/v2/avatars` list), using the `x-api-key` header.
    static func testHeyGen(apiKey: String, completion: @escaping (Result) -> Void) {
        guard !apiKey.isEmpty else { return finish(.invalid("Enter a key first."), completion) }
        guard let url = URL(string: "https://api.heygen.com/v1/user/me") else {
            return finish(.failed("Invalid URL."), completion)
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.timeoutInterval = 15
        send(req, completion) { code in
            switch code {
            case 200: return .ok("Key verified.")
            case 401, 403: return .invalid("Key rejected by HeyGen (\(code)).")
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

    /// Checks reachability of an OpenAI-compatible / custom TTS server. Local servers usually need
    /// no key, so this proves the URL is reachable rather than validating a credential. Tries a
    /// cheap `GET {base}/models`; a custom (non-/v1) URL is probed directly.
    static func testTTSEndpoint(baseURL: String, apiKey: String, openAICompatible: Bool,
                                completion: @escaping (Result) -> Void) {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return finish(.invalid("Enter a Base URL first."), completion) }
        let probe = openAICompatible ? base + "/models" : base
        guard let url = URL(string: probe) else { return finish(.failed("Invalid Base URL."), completion) }
        var req = URLRequest(url: url)
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 15
        send(req, completion) { code in
            switch code {
            case 200, 405: return .ok("Server reachable.")           // 405 = endpoint exists, wrong verb
            case 401, 403: return .invalid("Server rejected the key (\(code)).")
            case 404: return openAICompatible ? .ok("Server reachable (no /models).") : .ok("Endpoint reachable.")
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
