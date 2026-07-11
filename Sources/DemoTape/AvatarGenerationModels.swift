import Foundation

/// Provider-agnostic models for avatar-presenter generation. These are intentionally decoupled
/// from any specific vendor so a second provider could be added behind `AvatarVideoProvider`.

/// A selectable avatar from the provider's library.
struct AvatarDescriptor: Equatable {
    let id: String
    let name: String
    let previewImageURL: URL?
    let isPremium: Bool
    let gender: String?
}

/// Where the avatar comes from: a library avatar, or a photo the user uploaded.
enum AvatarSource: Equatable {
    case avatar(id: String)          // HeyGen library avatar (type:"avatar")
    case photo(imageAssetID: String) // user photo uploaded as an image asset (type:"image")
}

/// Output resolution. Defaults to 1080p per product requirement.
enum AvatarQuality: String, Equatable, CaseIterable {
    case p720 = "720p"
    case p1080 = "1080p"
    case p4k = "4k"
    var label: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p (recommended)"
        case .p4k: return "4K"
        }
    }
}

/// Where the avatar is composited over the screen video.
enum AvatarPosition: String, Equatable, CaseIterable {
    case bottomLeft, bottomRight
    var label: String { self == .bottomLeft ? "Bottom-left" : "Bottom-right" }
}

/// A request to generate an avatar video from already-uploaded narration audio.
struct AvatarGenerationRequest: Equatable {
    var source: AvatarSource
    var audioAssetID: String
    /// Solid chroma-key background color (hex). Default green; keyed out during compositing.
    var backgroundHex: String = "#00B140"
    var resolution: AvatarQuality = .p1080
    /// Optional body-motion prompt (photo avatars / Avatar V only; ignored/omitted otherwise).
    var motionPrompt: String?
    /// Engine tag for library avatars (`avatar_iii`/`avatar_iv`/`avatar_v`). Photo avatars omit it.
    var engine: String?
}

/// A created generation job.
struct AvatarJob: Equatable {
    let id: String
}

/// Poll result for a generation job.
enum AvatarJobStatus: Equatable {
    case pending
    case processing
    case completed(resultURL: URL)
    case failed(message: String)
}

/// Errors surfaced to the UI. Messages are safe to show (never contain the API key).
enum AvatarProviderError: LocalizedError, Equatable {
    case missingKey
    case http(status: Int, message: String)
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(String)
    case network(String)
    case cancelled
    case badResult(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No HeyGen API key configured."
        case .http(let s, let m): return "HeyGen error (HTTP \(s)): \(m)"
        case .rateLimited(let r):
            return "HeyGen is rate-limiting requests" + (r.map { " (retry in \(Int($0))s)" } ?? "") + "."
        case .decoding(let m): return "Unexpected response from HeyGen: \(m)"
        case .network(let m): return "Network error: \(m)"
        case .cancelled: return "Cancelled."
        case .badResult(let m): return "Invalid result: \(m)"
        }
    }
}
