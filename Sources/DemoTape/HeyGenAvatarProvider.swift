import Foundation

/// Abstraction over an avatar-video backend so the UI and compositor never touch a specific
/// vendor. A second provider can be added later without changing callers.
protocol AvatarVideoProvider {
    func listAvatars() throws -> [AvatarDescriptor]
    func uploadAudio(_ audioURL: URL) throws -> String        // returns asset_id
    func uploadImage(_ imageURL: URL) throws -> String        // returns image asset_id (photo path)
    func createVideo(_ request: AvatarGenerationRequest, idempotencyKey: String) throws -> AvatarJob
    func jobStatus(_ jobID: String) throws -> AvatarJobStatus
    func downloadResult(_ resultURL: URL, to destination: URL) throws
}

/// HeyGen implementation (verified against the current v3 Videos / v3 Assets / v2 Avatars /
/// v1 status APIs). All request bodies are built in isolated, pure functions so an API change
/// is a one-line edit and is fully unit-testable without the network.
///
/// Security: the API key is only ever sent in the `x-api-key` header and is never logged.
final class HeyGenAvatarProvider: AvatarVideoProvider {

    private let apiKey: String
    private let session: URLSession
    private let cancelled: () -> Bool

    // Endpoints (isolated for easy version bumps).
    private let avatarsURL = URL(string: "https://api.heygen.com/v2/avatars")!
    private let assetsURL  = URL(string: "https://api.heygen.com/v3/assets")!
    private let videosURL  = URL(string: "https://api.heygen.com/v3/videos")!
    private func statusURL(_ id: String) -> URL {
        URL(string: "https://api.heygen.com/v1/video_status.get?video_id=\(id)")!
    }

    init(apiKey: String, session: URLSession? = nil, isCancelled: @escaping () -> Bool = { false }) {
        self.apiKey = apiKey
        self.cancelled = isCancelled
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 120   // /v2/avatars can be a large payload
            cfg.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Pure encoders/parsers (unit-tested, no network)

    /// Builds the `/v3/videos` JSON body for a request. Validated field shapes.
    static func encodeCreateBody(_ r: AvatarGenerationRequest) throws -> Data {
        var body: [String: Any] = [
            "audio_asset_id": r.audioAssetID,
            "background": ["type": "color", "value": r.backgroundHex],
            "output_format": "mp4",
            "resolution": r.resolution.rawValue
        ]
        switch r.source {
        case .avatar(let id):
            body["type"] = "avatar"
            body["avatar_id"] = id
            if let engine = r.engine, !engine.isEmpty { body["engine"] = ["type": engine] }
        case .photo(let assetID):
            body["type"] = "image"
            body["image"] = ["type": "asset_id", "asset_id": assetID]
        }
        if let mp = r.motionPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !mp.isEmpty {
            body["motion_prompt"] = mp
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func parseAvatars(_ data: Data) throws -> [AvatarDescriptor] {
        struct Resp: Decodable {
            struct A: Decodable {
                let avatar_id: String
                let avatar_name: String?
                let preview_image_url: String?
                let premium: Bool?
                let gender: String?
            }
            struct D: Decodable { let avatars: [A]? }
            let data: D?
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let avatars = decoded.data?.avatars else {
            throw AvatarProviderError.decoding("no avatars in response")
        }
        return avatars.map {
            AvatarDescriptor(id: $0.avatar_id,
                             name: $0.avatar_name ?? $0.avatar_id,
                             previewImageURL: $0.preview_image_url.flatMap(URL.init(string:)),
                             isPremium: $0.premium ?? false,
                             gender: $0.gender)
        }
    }

    static func parseAssetID(_ data: Data) throws -> String {
        struct Resp: Decodable { struct D: Decodable { let asset_id: String? }; let data: D? }
        guard let id = (try? JSONDecoder().decode(Resp.self, from: data))?.data?.asset_id, !id.isEmpty else {
            throw AvatarProviderError.decoding("no asset_id in upload response")
        }
        return id
    }

    static func parseCreateResponse(_ data: Data) throws -> AvatarJob {
        struct Resp: Decodable { struct D: Decodable { let video_id: String? }; let data: D? }
        guard let id = (try? JSONDecoder().decode(Resp.self, from: data))?.data?.video_id, !id.isEmpty else {
            throw AvatarProviderError.decoding("no video_id in create response")
        }
        return AvatarJob(id: id)
    }

    static func parseStatus(_ data: Data) throws -> AvatarJobStatus {
        struct Resp: Decodable {
            struct D: Decodable {
                let status: String?
                let video_url: String?
                struct E: Decodable { let message: String? }
                let error: E?
            }
            let data: D?
            let code: Int?
            let message: String?
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        if let d = decoded.data {
            switch (d.status ?? "").lowercased() {
            case "completed", "success", "done":
                if let s = d.video_url, let url = URL(string: s) { return .completed(resultURL: url) }
                return .failed(message: "completed but no video_url")
            case "failed", "error":
                return .failed(message: d.error?.message ?? "generation failed")
            case "pending", "waiting", "queued":
                return .pending
            default:
                return .processing
            }
        }
        // Top-level error shape (v1 status uses {code,message}).
        return .failed(message: decoded.message ?? "unknown status response")
    }

    /// Extracts a human-safe error message from an error body (v3 `{error:{message,param}}`
    /// or v1 `{message}`). Never includes request headers.
    static func parseErrorMessage(_ data: Data) -> String {
        struct V3: Decodable { struct E: Decodable { let message: String?; let param: String? }; let error: E? }
        if let e = try? JSONDecoder().decode(V3.self, from: data), let m = e.error?.message {
            return e.error?.param.map { "\(m) (\($0))" } ?? m
        }
        struct V1: Decodable { let message: String? }
        if let e = try? JSONDecoder().decode(V1.self, from: data), let m = e.message { return m }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? "unknown error"
    }

    // MARK: - AvatarVideoProvider

    func listAvatars() throws -> [AvatarDescriptor] {
        let (data, _) = try send(get: avatarsURL)
        return try Self.parseAvatars(data)
    }

    func uploadAudio(_ audioURL: URL) throws -> String { try upload(audioURL) }
    func uploadImage(_ imageURL: URL) throws -> String { try upload(imageURL) }

    func createVideo(_ request: AvatarGenerationRequest, idempotencyKey: String) throws -> AvatarJob {
        var req = URLRequest(url: videosURL)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        req.httpBody = try Self.encodeCreateBody(request)
        let (data, _) = try perform(req)
        return try Self.parseCreateResponse(data)
    }

    func jobStatus(_ jobID: String) throws -> AvatarJobStatus {
        let (data, _) = try send(get: statusURL(jobID))
        return try Self.parseStatus(data)
    }

    func downloadResult(_ resultURL: URL, to destination: URL) throws {
        guard !cancelled() else { throw AvatarProviderError.cancelled }
        var req = URLRequest(url: resultURL)
        req.timeoutInterval = 600
        var outData: Data?, outResp: URLResponse?, outErr: Error?
        let sema = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { d, r, e in outData = d; outResp = r; outErr = e; sema.signal() }.resume()
        sema.wait()
        if cancelled() { throw AvatarProviderError.cancelled }
        if let e = outErr { throw AvatarProviderError.network(e.localizedDescription) }
        guard let http = outResp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let data = outData, !data.isEmpty else {
            throw AvatarProviderError.badResult("download failed")
        }
        // Validate it looks like a video, not an error page.
        let type = (outResp?.mimeType ?? "").lowercased()
        guard type.contains("video") || type.contains("octet-stream") || data.count > 100_000 else {
            throw AvatarProviderError.badResult("unexpected content type \(type)")
        }
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination)
    }

    // MARK: - Networking helpers

    private func upload(_ fileURL: URL) throws -> String {
        guard !cancelled() else { throw AvatarProviderError.cancelled }
        let boundary = "dt-\(UUID().uuidString)"
        var req = URLRequest(url: assetsURL)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        let mime = Self.mimeType(for: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (data, _) = try perform(req)
        return try Self.parseAssetID(data)
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    private func send(get url: URL) throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        return try perform(req)
    }

    /// Executes a request synchronously (callers run off the main thread), maps HTTP errors to
    /// typed errors, and honors Retry-After for 429.
    private func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard !cancelled() else { throw AvatarProviderError.cancelled }
        guard !apiKey.isEmpty else { throw AvatarProviderError.missingKey }
        var outData: Data?, outResp: URLResponse?, outErr: Error?
        let sema = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { d, r, e in outData = d; outResp = r; outErr = e; sema.signal() }.resume()
        sema.wait()
        if cancelled() { throw AvatarProviderError.cancelled }
        if let e = outErr { throw AvatarProviderError.network(e.localizedDescription) }
        guard let http = outResp as? HTTPURLResponse, let data = outData else {
            throw AvatarProviderError.network("no response")
        }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 429:
            let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw AvatarProviderError.rateLimited(retryAfter: retry)
        default:
            throw AvatarProviderError.http(status: http.statusCode, message: Self.parseErrorMessage(data))
        }
    }
}
