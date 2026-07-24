import XCTest
import CryptoKit
@testable import DemoTape

final class LicenseTests: XCTestCase {

    /// Mints a license with a throwaway keypair (mirrors LicenseSigner without touching disk).
    private func mint(name: String, key: Curve25519.Signing.PrivateKey) throws -> String {
        let (data, _) = try License.payload(name: name, issued: Date(), kind: "desktop-unlimited")
        let sig = try key.signature(for: data)
        return License.assemble(payload: data, signature: sig)
    }

    func testValidLicenseVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let license = try mint(name: "Alice", key: key)
        let info = License.verify(license, publicKeyBase64: pub)
        XCTAssertEqual(info?.name, "Alice")
        XCTAssertEqual(info?.kind, "desktop-unlimited")
    }

    func testTamperedPayloadRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        var license = try mint(name: "Alice", key: key)
        // Flip a character in the payload half.
        let idx = license.index(license.startIndex, offsetBy: 5)
        let repl: Character = license[idx] == "A" ? "B" : "A"
        license.replaceSubrange(idx...idx, with: String(repl))
        XCTAssertNil(License.verify(license, publicKeyBase64: pub))
    }

    func testWrongKeyRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let license = try mint(name: "Alice", key: key)
        XCTAssertNil(License.verify(license, publicKeyBase64: other))
    }

    func testEmptyOrMalformedRejected() {
        XCTAssertNil(License.verify("", publicKeyBase64: ""))
        XCTAssertNil(License.verify("not-a-license", publicKeyBase64: "also-bad"))
        let goodPub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertNil(License.verify("only-one-part", publicKeyBase64: goodPub))
        XCTAssertNil(License.verify("aaa.bbb", publicKeyBase64: goodPub))
    }

    func testEmbeddedKeyIsConfigured() {
        // This build ships a real public key (licensing is live).
        XCTAssertFalse(License.publicKeyBase64.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: License.publicKeyBase64))
    }
}
