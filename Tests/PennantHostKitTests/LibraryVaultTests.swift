import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Brand library storage and search, and the vault's rule that secrets reach scripts but never the model.
final class LibraryVaultTests: XCTestCase {
    private var paths: HostPaths!
    private var store: SQLiteStore!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
        store = try SQLiteStore(paths: paths)
    }

    override func tearDown() async throws {
        await store?.close()
        if let paths { try? FileManager.default.removeItem(at: paths.root) }
    }

    func testLibraryUploadListsPathsAndGuidance() async throws {
        let library = LibraryService(root: paths.root.appendingPathComponent("library"), store: store)
        _ = try await library.saveCollection(LibraryCollection(name: "Acme brand", notes: "Navy #1E3A8A. Logo top-left."))
        var index = try await library.upload(collection: "Acme brand", fileName: "logo.svg", mimeType: "image/svg+xml", data: Data("<svg/>".utf8), name: "Logo, dark", notes: "For light backgrounds")
        index = try await library.upload(collection: "Acme brand", fileName: "logo.svg", mimeType: "image/svg+xml", data: Data("<svg/>".utf8), name: "Logo, white", notes: "")
        XCTAssertEqual(index.assets.count, 2)
        XCTAssertNotEqual(index.assets[0].path, index.assets[1].path, "same file name must not overwrite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.assets[1].path))

        let text = FindAssetsTool.describe(index, query: "dark", collection: nil)
        XCTAssertTrue(text.contains("Navy #1E3A8A"))
        XCTAssertTrue(text.contains(index.assets[0].path))
        XCTAssertFalse(text.contains("Logo, white"))

        index = try await library.deleteCollection("Acme brand")
        XCTAssertTrue(index.assets.isEmpty)
    }

    /// A model's key can live in the Vault: read for each request, as a bearer token or in Azure's `api-key` header,
    /// and a model setup that names an entry gets it through the Vault, never the config.
    func testModelKeysComeFromTheVault() async throws {
        let vault = VaultService(store: store, keychain: KeychainStore(service: "test", fallbackFileURL: paths.root.appendingPathComponent("keys.json"), preferFile: true))
        _ = try await vault.save(VaultItem(name: "OpenRouter key", kind: .secret), secret: VaultSecret(secret: " sk-or-test-1 "))
        let bearer = try await VaultKeyAuthority(entry: "openrouter-key", baseURL: "https://openrouter.ai/api/v1", vault: vault).credential()
        XCTAssertEqual(bearer.bearer, "sk-or-test-1")
        let azure = try await VaultKeyAuthority(entry: "openrouter-key", baseURL: "https://x.openai.azure.com/openai/v1", header: "api-key", vault: vault).credential()
        XCTAssertEqual(azure.headers["api-key"], "sk-or-test-1")
        XCTAssertEqual(azure.bearer, "")
        do {
            _ = try await VaultKeyAuthority(entry: "missing", baseURL: "https://x", vault: vault).credential()
            XCTFail("a missing entry must fail")
        } catch { XCTAssertTrue(String(describing: error).contains("no entry named missing")) }

        let chatGPT = ChatGPTAuthManager(credentials: KeychainCredentialStore(keychain: KeychainStore(service: "test.c", fallbackFileURL: paths.root.appendingPathComponent("c.json"), preferFile: true)))
        var inference = HostConfig.Inference(baseURL: "https://openrouter.ai/api/v1", model: "x")
        inference.apiKeyVault = "openrouter-key"
        let provider = HostService.makeProvider(inference, chatGPT: chatGPT, vault: vault) as? OpenAICompatibleProvider
        XCTAssertTrue(provider?.authority is VaultKeyAuthority)
        let back = try JSONDecoder().decode(HostConfig.Inference.self, from: JSONEncoder().encode(inference))
        XCTAssertEqual(back.apiKeyVault, "openrouter-key")
        XCTAssertNil(back.apiKey)
    }

    func testRecordsAndForgetsCopiedSignIns() async throws {
        let vault = VaultService(store: store, keychain: KeychainStore(service: "test", fallbackFileURL: paths.root.appendingPathComponent("v.json"), preferFile: true))
        let until = Date(timeIntervalSinceNow: 86_400 * 300)
        var list = try await vault.recordSignIns(ChromeImportResult(profile: "Default", cookies: 44, perSite: ["linkedin.com": 44], expiresAt: ["linkedin.com": until]), profileName: "Your Chrome", account: "me@example.com")
        XCTAssertEqual(list.map(\.site), ["linkedin.com"])
        XCTAssertEqual(list.first?.cookies, 44)
        XCTAssertEqual(list.first?.expiresAt, until)
        // A second import of the same site replaces the record instead of adding a duplicate.
        list = try await vault.recordSignIns(ChromeImportResult(profile: "Default", cookies: 40, perSite: ["linkedin.com": 40, "reddit.com": 9]), profileName: "Your Chrome", account: nil)
        XCTAssertEqual(list.map(\.site), ["linkedin.com", "reddit.com"])
        XCTAssertEqual(list.first?.cookies, 40)
        list = try await vault.forgetSignIn("linkedin.com")
        XCTAssertEqual(list.map(\.site), ["reddit.com"])
    }

    func testVaultKeepsSecretsOutOfListingsAndRedactsThem() async throws {
        let keychain = KeychainStore(service: "test", fallbackFileURL: paths.root.appendingPathComponent("vault.json"), preferFile: true)
        let vault = VaultService(store: store, keychain: keychain)
        let items = try await vault.save(VaultItem(name: "LinkedIn", url: "https://www.linkedin.com", username: "me@example.com"),
                                         secret: VaultSecret(password: "hunter2-long", totp: "jbsw y3dp"))
        XCTAssertEqual(items.first?.name, "linkedin")
        XCTAssertEqual(items.first?.hasPassword, true)
        XCTAssertEqual(items.first?.hasTOTP, true)
        let encoded = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        XCTAssertFalse(encoded.contains("hunter2"))

        // Saving again without secrets keeps them.
        var item = items[0]
        item.notes = "admin"
        _ = try await vault.save(item, secret: nil)
        let resolved = await vault.resolve(["linkedin"])
        XCTAssertEqual(resolved.entries["linkedin"]?["password"], "hunter2-long")
        XCTAssertEqual(resolved.entries["linkedin"]?["totp"], "JBSWY3DP")
        XCTAssertEqual(BrowserRunner.redact("{\"echo\":\"hunter2-long\"}", resolved.secrets), "{\"echo\":\"[redacted]\"}")

        let missing = await vault.resolve(["github"])
        XCTAssertEqual(missing.missing, ["github"])
        XCTAssertTrue(missing.entries.isEmpty)
        let listing = try await VaultListTool(vault: vault).invoke(.object([:]), context: ToolContext(agentID: AgentID(), taskID: TaskID(), conversationID: ConversationID(), store: store, desktop: FakeDesktop(), lease: DesktopLease(pauseOnHumanInput: false, desktop: FakeDesktop(), onChange: { _ in }), config: HostConfig()))
        XCTAssertFalse(listing.textContent.contains("hunter2"))
        XCTAssertTrue(listing.textContent.contains("authenticator code"))
    }
}

import CommonCrypto

final class ChromeSignInsTests: XCTestCase {
    /// Encrypts like Chrome ("v10" + AES-128-CBC, IV of spaces, optional SHA-256(host) prefix) and decrypts back.
    func testDecryptsChromeCookieFormat() {
        let key = ChromeSignIns.derive(password: Data("peanuts".utf8))
        XCTAssertEqual(key.count, 16)
        for prefixed in [false, true] {
            var plain = [UInt8]("AQEDAS-session-value".utf8)
            if prefixed { plain = [UInt8](repeating: 7, count: 32) + plain }
            var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
            let outCount = out.count
            var moved = 0
            let k = [UInt8](key), iv = [UInt8](repeating: 0x20, count: 16)
            XCTAssertEqual(CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k, 16, iv, plain, plain.count, &out, outCount, &moved), CCCryptorStatus(kCCSuccess))
            let blob = Data("v10".utf8) + Data(out.prefix(moved))
            XCTAssertEqual(ChromeSignIns.decrypt(blob, key: key, hostDigestPrefix: prefixed), "AQEDAS-session-value")
        }
        XCTAssertNil(ChromeSignIns.decrypt(Data("v11abc".utf8), key: key, hostDigestPrefix: false))
    }

    func testSiteMatching() {
        XCTAssertEqual(ChromeSignIns.normalize("https://www.LinkedIn.com/feed"), "linkedin.com")
        XCTAssertTrue(ChromeSignIns.matches(host: ".linkedin.com", site: "linkedin.com"))
        XCTAssertTrue(ChromeSignIns.matches(host: "www.linkedin.com", site: "linkedin.com"))
        XCTAssertFalse(ChromeSignIns.matches(host: "notlinkedin.com", site: "linkedin.com"))
    }
}

final class ChromeSiteGroupingTests: XCTestCase {
    func testGroupsHostsBySite() {
        XCTAssertEqual(ChromeSignIns.registrableDomain(".www.linkedin.com"), "linkedin.com")
        XCTAssertEqual(ChromeSignIns.registrableDomain("linkedin.com"), "linkedin.com")
        XCTAssertEqual(ChromeSignIns.registrableDomain("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(ChromeSignIns.registrableDomain("localhost"), "localhost")
    }
}

final class RedactionTests: XCTestCase {
    func testShortValuesDoNotCorruptResults() {
        XCTAssertEqual(BrowserRunner.redact(#"{"ok":true,"count":12}"#, ["true", "12", "AQEDASecretLongValue"]), #"{"ok":true,"count":12}"#)
        XCTAssertEqual(BrowserRunner.redact("token AQEDASecretLongValue", ["AQEDASecretLongValue"]), "token [redacted]")
    }
}
