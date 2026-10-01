import CryptoKit
import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class PushServiceTests: XCTestCase {
    var paths: HostPaths!
    override func setUp() async throws { paths = HostPaths.temporary(); try paths.ensureDirectories() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service() -> PushService {
        PushService(paths: paths, keychain: KeychainStore(service: "test.push", fallbackFileURL: paths.root.appendingPathComponent("push.json"), preferFile: true))
    }

    func testKeysAreCheckedAndTokensSignedTheWayAppleWants() async throws {
        let push = service()
        let key = P256.Signing.PrivateKey()
        do { try await push.setKey(keyID: "ABC", teamID: "TEAM123456", p8: key.pemRepresentation); XCTFail("a short key id is refused") } catch {}
        do { try await push.setKey(keyID: "ABCDE12345", teamID: "TEAM123456", p8: "not a key"); XCTFail("a non-key is refused") } catch {}
        try await push.setKey(keyID: "ABCDE12345", teamID: "TEAM123456", p8: key.pemRepresentation)
        let status = await push.status()
        XCTAssertTrue(status.keyConfigured)
        XCTAssertEqual(status.keyID, "ABCDE12345")

        let jwt = try await push.token(now: Date(timeIntervalSince1970: 1_800_000_000))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func data(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let header = try JSONSerialization.jsonObject(with: data(parts[0])) as! [String: Any]
        let claims = try JSONSerialization.jsonObject(with: data(parts[1])) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "ABCDE12345")
        XCTAssertEqual(claims["iss"] as? String, "TEAM123456")
        XCTAssertEqual(claims["iat"] as? Int, 1_800_000_000)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: data(parts[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    func testDevicesPersistAndNothingIsSentWithoutAKey() async throws {
        let push = service()
        try await push.register(PushDevice(token: "abc", environment: "development", personID: PersonID("owner"), name: "iPhone", bundleID: "dev.pennant.ios"), teamID: "TEAM123456")
        let sent = await push.notify(title: "t", body: "b", to: [], key: "k")
        XCTAssertEqual(sent, 0, "no key yet")
        let again = service()
        let status = await again.status()
        XCTAssertEqual(status.devices.map(\.token), ["abc"])
        XCTAssertEqual(status.teamID, "TEAM123456", "the app's team id is kept")
    }
}
