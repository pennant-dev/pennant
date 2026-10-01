import PennantCore
@testable import PennantHostKit
import Foundation
import Security
import XCTest

/// A coding agent acts on GitHub as its own App or not at all: never under the owner's login.
final class GitHubIdentityTests: XCTestCase {
    final class Seen: @unchecked Sendable { var requests: [URLRequest] = [] }

    private func rsaKey() throws -> (pem: String, key: SecKey) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, &error) as Data?)
        // As GitHub hands it out: PKCS#1, flattened onto one line the way a pasted Vault field keeps it. (The armour is
        // put together here so no key-shaped text sits in the source.)
        let label = "RSA " + "PRIVATE KEY"
        return ("-----BEGIN \(label)-----" + der.base64EncodedString() + "-----END \(label)-----", key)
    }

    func testASessionGetsTheAppsTokenAndCommitsAsItsBot() async throws {
        let (pem, key) = try rsaKey()
        let seen = Seen()
        let minter = GitHubAppToken { request in
            seen.requests.append(request)
            if request.url!.path.hasSuffix("/access_tokens") { return (Data(#"{"token":"ghs_test"}"#.utf8), 201) }
            return (Data(#"{"id":123456}"#.utf8), 200)
        }
        let app = GitHubAppIdentity(appID: 42, installationID: 7, vaultEntry: "app-key", slug: "example-bot")
        let env = try await minter.environment(for: app, privateKeyPEM: pem)

        let mint = try XCTUnwrap(seen.requests.first)
        XCTAssertEqual(mint.url?.absoluteString, "https://api.github.com/app/installations/7/access_tokens")
        XCTAssertEqual(mint.httpMethod, "POST")
        // The JWT is the App's, signed with its key.
        let jwt = String(try XCTUnwrap(mint.value(forHTTPHeaderField: "Authorization")).dropFirst("Bearer ".count))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func unb64(_ s: String) -> Data {
            var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)!
        }
        XCTAssertTrue(String(decoding: unb64(parts[1]), as: UTF8.self).contains(#""iss":"42""#))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData, unb64(parts[2]) as CFData, nil))

        XCTAssertEqual(env["GH_TOKEN"], "ghs_test")
        XCTAssertEqual(env["GIT_AUTHOR_NAME"], "example-bot[bot]")
        XCTAssertEqual(env["GIT_COMMITTER_EMAIL"], "123456+example-bot[bot]@users.noreply.github.com")
        XCTAssertEqual(env["PENNANT_GITHUB_IDENTITY"], "example-bot[bot]")
        // git: the owner's credential helper is cleared, gh's is used, and SSH remotes go over HTTPS with the token.
        let count = try XCTUnwrap(Int(env["GIT_CONFIG_COUNT"] ?? ""))
        let config = (0..<count).map { (env["GIT_CONFIG_KEY_\($0)"]!, env["GIT_CONFIG_VALUE_\($0)"]!) }
        XCTAssertEqual(config.first?.0, "credential.helper")
        XCTAssertEqual(config.first?.1, "", "an empty helper first resets the owner's keychain helper")
        XCTAssertTrue(config.contains { $0 == ("credential.helper", "!gh auth git-credential") })
        XCTAssertTrue(config.contains { $0 == ("url.https://github.com/.insteadOf", "git@github.com:") })
    }

    func testARefusedKeySaysWhy() async throws {
        let (pem, _) = try rsaKey()
        let minter = GitHubAppToken { _ in (Data(#"{"message":"A JSON web token could not be decoded"}"#.utf8), 401) }
        do {
            _ = try await minter.environment(for: GitHubAppIdentity(appID: 1, installationID: 2, vaultEntry: "k", slug: "b"), privateKeyPEM: pem)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue("\(error)".contains("could not be decoded"), "\(error)")
        }
        XCTAssertThrowsError(try GitHubAppToken.privateKey(pem: "not a key"))
    }

    func testWithoutAnIdentityNothingGoesToGitHubAsTheOwner() {
        let none: String? = nil
        for write in ["git push -u origin feat/x", "cd repo && gh pr create --base main --title T --body B", "gh pr merge 12 --squash",
                      "gh issue comment 5 --body hi", "gh api -X POST repos/o/r/issues -f title=x", "gh release create v1"] {
            XCTAssertNotNil(GitHubGuard.refusal(write, identity: none), write)
        }
        for fine in ["git status", "git commit -m 'wip'", "git fetch origin", "gh pr view 12", "gh api repos/o/r/pulls", "gh pr checks 12"] {
            XCTAssertNil(GitHubGuard.refusal(fine, identity: none), fine)
        }
    }

    func testWithItsOwnIdentityItWorksNormallyButNeverSwapsWhoItIs() {
        let bot = "example-bot[bot]"
        for fine in ["git push -u origin feat/x", "gh pr create --base main --title T --body B", "gh pr comment 12 --body done", "git config user.name", "git config --get user.email", "git config user.name 2>&1", "git config user.email > /tmp/who",
                     #"echo "2) $(git config user.name 2>&1)"; echo "3) $(git config user.email 2>&1)"; echo "4) $PENNANT_GITHUB_IDENTITY""#] {
            XCTAssertNil(GitHubGuard.refusal(fine, identity: bot), fine)
        }
        for swap in ["gh auth login --with-token < t", "gh auth switch -u maya-okafor", "GH_TOKEN=$(cat ~/t) gh pr create",
                     "git config user.email me@example.com", "git -c credential.helper=osxkeychain push", "unset GH_TOKEN; gh pr create"] {
            XCTAssertNotNil(GitHubGuard.refusal(swap, identity: bot), swap)
        }
    }

    /// Settings › Pennant › Coding checks an identity before saving it: the host mints a token with the Vault's key,
    /// and says why when it can't.
    func testCheckingAnIdentityMintsATokenWithTheVaultsKey() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let s = try HostService(paths: paths, config: HostConfig(workingDirectory: paths.root.path), desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: ScriptedProvider([]))
        let app = GitHubAppIdentity(appID: 42, installationID: 7, vaultEntry: "example-app-key", slug: "example-bot")
        let missing = await s.handle(.checkGitHubApp(app), from: ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t"))
        guard case .error(_, let message) = missing else { return XCTFail("expected an error, got \(missing)") }
        XCTAssertEqual(message, #"Couldn't act as example-bot[bot]: the Vault has no private key under "example-app-key""#)

        // With the key in the Vault, as Settings saves it, the token is minted with it.
        let (pem, _) = try rsaKey()
        _ = try await s.vault.save(VaultItem(name: "example-app-key", kind: .secret), secret: VaultSecret(secret: pem))
        let minter = GitHubAppToken { request in
            request.url!.path.hasSuffix("/access_tokens") ? (Data(#"{"token":"ghs_test"}"#.utf8), 201) : (Data("{}".utf8), 404)
        }
        let environment = try await HostService.gitHubEnvironment(for: app, vault: s.vault, minter: minter)
        XCTAssertEqual(environment["GH_TOKEN"], "ghs_test")
        XCTAssertEqual(environment["GIT_AUTHOR_NAME"], "example-bot[bot]")
    }
}
