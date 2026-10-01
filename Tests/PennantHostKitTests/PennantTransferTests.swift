import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Moving Pennant between Macs: export, sealed secrets, staging, and the swap at the next start.
final class PennantTransferTests: XCTestCase {
    override func setUp() { setenv("PENNANT_KEYCHAIN_FALLBACK", "1", 1) }   // never touch the real Keychain

    func testRoundTripKeepsDataSealsSecretsAndKeepsThePreviousCopy() async throws {
        let source = HostPaths.temporary(), target = HostPaths.temporary()
        let exports = FileManager.default.temporaryDirectory.appendingPathComponent("exports-\(UUID().uuidString)", isDirectory: true)
        defer { for u in [source.root, target.root, exports] { try? FileManager.default.removeItem(at: u) } }
        try source.ensureDirectories(); try target.ensureDirectories()

        // Source Mac: a setting, a library file, a vault secret.
        let store = try SQLiteStore(paths: source)
        try await store.setSetting("marker", value: "from-source")
        let lib = source.root.appendingPathComponent("library/brand", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("<svg/>".utf8).write(to: lib.appendingPathComponent("logo.svg"))
        try Data(#"{"mode":"everyday"}"#.utf8).write(to: source.configURL)
        try KeychainStore(service: "dev.pennant.host.vault", fallbackFileURL: source.root.appendingPathComponent("vault-fallback.json")).set(account: "item-1", value: #"{"password":"s3cret-pass"}"#)

        let result = try await PennantTransfer.export(store: store, paths: source, into: exports, passphrase: "correct horse")
        await store.close()
        XCTAssertEqual(result.secrets, 1)
        let dir = URL(fileURLWithPath: result.path)
        let sealed = try String(contentsOf: dir.appendingPathComponent("secrets.pennant"), encoding: .utf8)
        XCTAssertFalse(sealed.contains("s3cret"), "secrets are sealed, not plain")

        // Target Mac: a wrong passphrase stages nothing; the right one stages, and the next start swaps it in.
        XCTAssertThrowsError(try PennantTransfer.stage(from: dir, passphrase: "wrong", paths: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.root.appendingPathComponent(".restore").path))
        try Data("old".utf8).write(to: target.configURL)
        try PennantTransfer.stage(from: dir, passphrase: "correct horse", paths: target)
        XCTAssertTrue(PennantTransfer.applyPendingImport(paths: target))

        let restored = try SQLiteStore(paths: target)
        let marker = try await restored.setting("marker")
        XCTAssertEqual(marker, "from-source")
        await restored.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("library/brand/logo.svg").path))
        XCTAssertEqual(KeychainStore(service: "dev.pennant.host.vault", fallbackFileURL: target.root.appendingPathComponent("vault-fallback.json")).get(account: "item-1"), #"{"password":"s3cret-pass"}"#)
        let kept = try FileManager.default.contentsOfDirectory(atPath: target.root.path).filter { $0.hasPrefix("before-import-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try String(contentsOf: target.root.appendingPathComponent(kept[0]).appendingPathComponent("config.json"), encoding: .utf8), "old")
        XCTAssertFalse(PennantTransfer.applyPendingImport(paths: target), "nothing left to apply")
    }
}
