import XCTest
@testable import DemoTape

/// Unit tests for the HeyGen provider: request-body encoding, response parsing, and mocked
/// network behavior (upload/create/poll/errors). No real network calls, no API key.
final class HeyGenAvatarProviderTests: XCTestCase {

    // MARK: - Encoding

    func testEncodeCreateBodyForLibraryAvatar() throws {
        let req = AvatarGenerationRequest(source: .avatar(id: "Abigail_x"),
                                          audioAssetID: "aud123",
                                          backgroundHex: "#00B140",
                                          resolution: .p1080,
                                          motionPrompt: nil,
                                          engine: "avatar_iii")
        let data = try HeyGenAvatarProvider.encodeCreateBody(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "avatar")
        XCTAssertEqual(json["avatar_id"] as? String, "Abigail_x")
        XCTAssertEqual(json["audio_asset_id"] as? String, "aud123")
        XCTAssertEqual(json["output_format"] as? String, "mp4")
        XCTAssertEqual(json["resolution"] as? String, "1080p")
        XCTAssertEqual((json["background"] as? [String: Any])?["type"] as? String, "color")
        XCTAssertEqual((json["background"] as? [String: Any])?["value"] as? String, "#00B140")
        XCTAssertEqual((json["engine"] as? [String: Any])?["type"] as? String, "avatar_iii")
        XCTAssertNil(json["motion_prompt"], "no motion prompt when nil")
        XCTAssertNil(json["image"])
    }

    func testEncodeCreateBodyForPhotoWithMotion() throws {
        let req = AvatarGenerationRequest(source: .photo(imageAssetID: "img99"),
                                          audioAssetID: "aud1",
                                          motionPrompt: "gentle hand gestures",
                                          engine: nil)
        let data = try HeyGenAvatarProvider.encodeCreateBody(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "image")
        let image = try XCTUnwrap(json["image"] as? [String: Any])
        XCTAssertEqual(image["type"] as? String, "asset_id")
        XCTAssertEqual(image["asset_id"] as? String, "img99")
        XCTAssertEqual(json["motion_prompt"] as? String, "gentle hand gestures")
        XCTAssertNil(json["avatar_id"])
        XCTAssertNil(json["engine"])
    }

    func testEncodeOmitsBlankMotionPrompt() throws {
        let req = AvatarGenerationRequest(source: .photo(imageAssetID: "i"), audioAssetID: "a",
                                          motionPrompt: "   ")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: HeyGenAvatarProvider.encodeCreateBody(req)) as? [String: Any])
        XCTAssertNil(json["motion_prompt"])
    }

    // MARK: - Parsing

    func testParseAvatars() throws {
        let json = """
        {"error":null,"data":{"avatars":[
          {"avatar_id":"a1","avatar_name":"Abigail","preview_image_url":"https://x/y.webp","premium":false,"gender":"female"},
          {"avatar_id":"a2","avatar_name":"Bob","preview_image_url":null,"premium":true,"gender":"male"}
        ]}}
        """.data(using: .utf8)!
        let avatars = try HeyGenAvatarProvider.parseAvatars(json)
        XCTAssertEqual(avatars.count, 2)
        XCTAssertEqual(avatars[0].id, "a1")
        XCTAssertEqual(avatars[0].name, "Abigail")
        XCTAssertEqual(avatars[0].previewImageURL?.absoluteString, "https://x/y.webp")
        XCTAssertFalse(avatars[0].isPremium)
        XCTAssertTrue(avatars[1].isPremium)
        XCTAssertNil(avatars[1].previewImageURL)
    }

    func testParseAssetID() throws {
        let json = #"{"data":{"asset_id":"asset_abc","url":"https://x","mime_type":"audio/mpeg","size_bytes":123}}"#.data(using: .utf8)!
        XCTAssertEqual(try HeyGenAvatarProvider.parseAssetID(json), "asset_abc")
        XCTAssertThrowsError(try HeyGenAvatarProvider.parseAssetID(#"{"data":{}}"#.data(using: .utf8)!))
    }

    func testParseCreateResponse() throws {
        let json = #"{"data":{"video_id":"vid_1","status":"pending","output_format":"mp4"}}"#.data(using: .utf8)!
        XCTAssertEqual(try HeyGenAvatarProvider.parseCreateResponse(json).id, "vid_1")
    }

    func testParseStatusVariants() throws {
        let completed = #"{"data":{"status":"completed","video_url":"https://cdn/v.mp4"}}"#.data(using: .utf8)!
        if case .completed(let url) = try HeyGenAvatarProvider.parseStatus(completed) {
            XCTAssertEqual(url.absoluteString, "https://cdn/v.mp4")
        } else { XCTFail("expected completed") }

        let processing = #"{"data":{"status":"processing","video_url":null}}"#.data(using: .utf8)!
        XCTAssertEqual(try HeyGenAvatarProvider.parseStatus(processing), .processing)

        let pending = #"{"data":{"status":"pending"}}"#.data(using: .utf8)!
        XCTAssertEqual(try HeyGenAvatarProvider.parseStatus(pending), .pending)

        let failed = #"{"data":{"status":"failed","error":{"message":"bad avatar"}}}"#.data(using: .utf8)!
        XCTAssertEqual(try HeyGenAvatarProvider.parseStatus(failed), .failed(message: "bad avatar"))
    }

    func testParseErrorMessages() {
        let v3 = #"{"error":{"code":"invalid_parameter","message":"Field required","param":"background.type"}}"#.data(using: .utf8)!
        XCTAssertEqual(HeyGenAvatarProvider.parseErrorMessage(v3), "Field required (background.type)")
        let v1 = #"{"code":400569,"message":"Video(s) not found: x"}"#.data(using: .utf8)!
        XCTAssertEqual(HeyGenAvatarProvider.parseErrorMessage(v1), "Video(s) not found: x")
    }

    // MARK: - Mocked network

    private func provider(handler: @escaping (URLRequest) -> (Int, [String: String], Data)) -> HeyGenAvatarProvider {
        MockURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return HeyGenAvatarProvider(apiKey: "test-key", session: URLSession(configuration: cfg))
    }

    func testListAvatarsOverMockedNetwork() throws {
        let p = provider { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "test-key")
            let body = #"{"data":{"avatars":[{"avatar_id":"a1","avatar_name":"Abigail"}]}}"#.data(using: .utf8)!
            return (200, [:], body)
        }
        let avatars = try p.listAvatars()
        XCTAssertEqual(avatars.map { $0.id }, ["a1"])
    }

    func testCreateVideoSendsIdempotencyKeyAndBody() throws {
        var seenIdempotency: String?
        var seenBody: [String: Any]?
        let p = provider { req in
            seenIdempotency = req.value(forHTTPHeaderField: "Idempotency-Key")
            if let d = MockURLProtocol.bodyData(from: req) {
                seenBody = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            return (200, [:], #"{"data":{"video_id":"vid_9"}}"#.data(using: .utf8)!)
        }
        let req = AvatarGenerationRequest(source: .avatar(id: "a1"), audioAssetID: "aud",
                                          engine: "avatar_iii")
        let job = try p.createVideo(req, idempotencyKey: "idem-123")
        XCTAssertEqual(job.id, "vid_9")
        XCTAssertEqual(seenIdempotency, "idem-123")
        XCTAssertEqual(seenBody?["audio_asset_id"] as? String, "aud")
    }

    func testJobStatusCompletedOverMockedNetwork() throws {
        let p = provider { _ in (200, [:], #"{"data":{"status":"completed","video_url":"https://cdn/v.mp4"}}"#.data(using: .utf8)!) }
        XCTAssertEqual(try p.jobStatus("vid"), .completed(resultURL: URL(string: "https://cdn/v.mp4")!))
    }

    func testRateLimitMapsToRateLimited() {
        let p = provider { _ in (429, ["Retry-After": "12"], Data("{}".utf8)) }
        XCTAssertThrowsError(try p.listAvatars()) { error in
            XCTAssertEqual(error as? AvatarProviderError, .rateLimited(retryAfter: 12))
        }
    }

    func testHTTPErrorMapsWithParsedMessage() {
        let p = provider { _ in (400, [:], #"{"error":{"code":"invalid_parameter","message":"nope"}}"#.data(using: .utf8)!) }
        XCTAssertThrowsError(try p.listAvatars()) { error in
            XCTAssertEqual(error as? AvatarProviderError, .http(status: 400, message: "nope"))
        }
    }
}

/// Minimal URLProtocol stub for deterministic, offline provider tests.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    /// Reads the request body whether URLSession kept it in httpBody or an httpBodyStream.
    static func bodyData(from req: URLRequest) -> Data? {
        if let b = req.httpBody { return b }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); let size = 4096; var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: size)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "mock", code: 0)); return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
