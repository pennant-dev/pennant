import PennantCore
@testable import PennantHostKit
import XCTest

/// Pennant was called Cove, then Ayes, while it was built: the data folder moves once and leaves every old name as a
/// link, files take their names now, and Keychain secrets are found under whichever older name they still live, then
/// copied to the new one.
final class RenameMigrationTests: XCTestCase {
    private func tempBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func link(_ base: URL, _ name: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: base.appendingPathComponent(name).path)
    }

    func testTheAyesFolderMovesAndEveryOldPathStillWorks() throws {
        let base = try tempBase()
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("Ayes/skills", isDirectory: true), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: base.appendingPathComponent("Ayes/cove.sqlite"))
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("Cove").path, withDestinationPath: "Ayes")

        XCTAssertNotNil(DataFolder.migrateLegacy(in: base))
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("Pennant/cove.sqlite"), encoding: .utf8), "db")
        XCTAssertEqual(link(base, "Ayes"), "Pennant")
        XCTAssertEqual(link(base, "Cove"), "Pennant", "the older link points straight at the new folder")
        XCTAssertTrue(fm.fileExists(atPath: base.appendingPathComponent("Ayes/skills").path))
        XCTAssertTrue(fm.fileExists(atPath: base.appendingPathComponent("Cove/skills").path))
        XCTAssertNil(DataFolder.migrateLegacy(in: base), "a second run does nothing")
    }

    func testAFolderNeverMigratedFromCoveGoesStraightToPennant() throws {
        let base = try tempBase()
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Cove"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: base.appendingPathComponent("Cove/cove.sqlite"))

        XCTAssertNotNil(DataFolder.migrateLegacy(in: base))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("Pennant/cove.sqlite").path))
        XCTAssertEqual(link(base, "Cove"), "Pennant")
        XCTAssertEqual(link(base, "Ayes"), "Pennant")
    }

    func testAnAppMadePennantFolderGivesWayToTheRealData() throws {
        let base = try tempBase()
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Ayes"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: base.appendingPathComponent("Ayes/cove.sqlite"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Pennant/logs"), withIntermediateDirectories: true)

        XCTAssertNotNil(DataFolder.migrateLegacy(in: base))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("Pennant/cove.sqlite").path))
    }

    func testTwoRealFoldersAreLeftAlone() throws {
        let base = try tempBase()
        for name in ["Ayes", "Pennant"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: base.appendingPathComponent("\(name)/cove.sqlite"))
        }
        _ = DataFolder.migrateLegacy(in: base)
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("Pennant/cove.sqlite"), encoding: .utf8), "Pennant")
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("Ayes/cove.sqlite"), encoding: .utf8), "Ayes")
    }

    /// The database and an export's sealed secrets take their names now; a file that already has the new name wins.
    func testFilesFromBeforeTheRenameTakeTheirNamesNow() throws {
        let base = try tempBase()
        let fm = FileManager.default
        for name in ["cove.sqlite", "cove.sqlite-wal", "secrets.cove"] { try Data(name.utf8).write(to: base.appendingPathComponent(name)) }
        HostPaths.adoptRenamedFiles(in: base)
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("pennant.sqlite"), encoding: .utf8), "cove.sqlite")
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("pennant.sqlite-wal"), encoding: .utf8), "cove.sqlite-wal")
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("secrets.pennant"), encoding: .utf8), "secrets.cove")
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("cove.sqlite").path))

        try Data("older".utf8).write(to: base.appendingPathComponent("cove.sqlite"))
        HostPaths.adoptRenamedFiles(in: base)
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("pennant.sqlite"), encoding: .utf8), "cove.sqlite", "the current file stays")
    }

    func testASecretIsFoundUnderEitherOlderNameTheFirstTimeItIsNeeded() throws {
        let root = try tempBase()
        let ayesFile = root.appendingPathComponent("ayes.json"), newFile = root.appendingPathComponent("new.json")
        // Where the chained Cove store keeps its file-fallback secrets in this test.
        let coveFile = root.appendingPathComponent(".no-legacy-fallback-io.cove.host.mcp.json")
        try KeychainStore(service: "dev.ayes.host.mcp", fallbackFileURL: ayesFile, preferFile: true).set(account: "github", value: "gho_token_123456")
        try KeychainStore(service: "io.cove.host.mcp", fallbackFileURL: coveFile, preferFile: true).set(account: "notion", value: "secret_notion_1")
        let new = KeychainStore(service: "dev.pennant.host.mcp", fallbackFileURL: newFile, preferFile: true,
                                legacyService: "dev.ayes.host.mcp", legacyFallbackFileURL: ayesFile)

        XCTAssertEqual(new.get(account: "github"), "gho_token_123456", "found under the Ayes name")
        XCTAssertEqual(new.get(account: "notion"), "secret_notion_1", "found under the Cove name, through the Ayes store")
        let plainNew = KeychainStore(service: "dev.pennant.host.mcp", fallbackFileURL: newFile, preferFile: true)
        XCTAssertEqual(plainNew.get(account: "github"), "gho_token_123456", "copied under the new name")
        XCTAssertEqual(plainNew.get(account: "notion"), "secret_notion_1")

        XCTAssertEqual(KeychainMigration.legacyName(for: "dev.pennant.host.vault"), "dev.ayes.host.vault")
        XCTAssertEqual(KeychainMigration.legacyName(for: "dev.ayes.host.vault"), "io.cove.host.vault")
    }
}
