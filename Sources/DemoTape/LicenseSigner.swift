import Foundation
import CryptoKit

/// Issuer-side licensing (runs on YOUR machine via the CLI). Holds the Ed25519 private key and
/// mints signed licenses. The private key lives in Application Support, chmod 600 — never in the
/// app bundle or the repo. Verification (`License`) only ever needs the public half.
enum LicenseSigner {

    /// Where the signing private key is stored on the issuer's machine.
    static var privateKeyURL: URL {
        Paths.supportDirectory.appendingPathComponent("license_signing.key")
    }

    enum SignerError: LocalizedError {
        case noKey, badKey, writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "No signing key found. Run `DemoTape --license-keygen` first."
            case .badKey: return "The stored signing key is unreadable."
            case .writeFailed(let m): return "Couldn't save the signing key: \(m)"
            }
        }
    }

    /// Generates a fresh keypair, saves the private key locally (0600), and returns the PUBLIC key
    /// as base64 to paste into `License.publicKeyBase64`. Refuses to clobber an existing key unless
    /// `force` is set (regenerating invalidates every license already issued).
    @discardableResult
    static func generateKeypair(force: Bool = false) throws -> String {
        let url = privateKeyURL
        if FileManager.default.fileExists(atPath: url.path) && !force {
            // Return the existing public key rather than overwrite.
            return try existingPublicKeyBase64()
        }
        let key = Curve25519.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        do {
            try key.rawRepresentation.base64EncodedData().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw SignerError.writeFailed(error.localizedDescription) }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// The public key corresponding to the stored private key.
    static func existingPublicKeyBase64() throws -> String {
        try loadPrivateKey().publicKey.rawRepresentation.base64EncodedString()
    }

    /// Mints a signed license string for `name`.
    static func issue(name: String, kind: String = "desktop-unlimited") throws -> String {
        let key = try loadPrivateKey()
        let (data, _) = try License.payload(name: name, issued: Date(), kind: kind)
        let signature = try key.signature(for: data)
        return License.assemble(payload: data, signature: signature)
    }

    private static func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        guard let raw = try? Data(contentsOf: privateKeyURL),
              let decoded = Data(base64Encoded: raw) else { throw SignerError.noKey }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: decoded) else {
            throw SignerError.badKey
        }
        return key
    }
}
