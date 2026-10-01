import PennantClientKit
import XCTest

/// Settings saved under "cove." keys take their "pennant." names once; a setting already saved under the new name
/// wins.
final class LegacyDefaultsTests: XCTestCase {
    func testOldKeysTakeTheirNewNamesOnce() throws {
        let name = "legacy-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("mac.local", forKey: "cove.host")
        defaults.set(7331, forKey: "cove.port")
        defaults.set("dark", forKey: "cove.appearance")
        defaults.set("light", forKey: "pennant.appearance")

        LegacyDefaults.migrate(defaults)
        XCTAssertEqual(defaults.string(forKey: "pennant.host"), "mac.local")
        XCTAssertEqual(defaults.integer(forKey: "pennant.port"), 7331)
        XCTAssertEqual(defaults.string(forKey: "pennant.appearance"), "light", "the newer setting wins")
        XCTAssertNil(defaults.object(forKey: "cove.host"))

        defaults.set("again.local", forKey: "cove.host")
        LegacyDefaults.migrate(defaults)
        XCTAssertEqual(defaults.string(forKey: "pennant.host"), "mac.local", "it runs once")
    }
}
