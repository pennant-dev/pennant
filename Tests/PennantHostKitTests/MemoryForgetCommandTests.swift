import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// `pennant memory forget <id>` tries a fact, then a standing instruction: forgetting an id that isn't a fact must say
/// so, or the instruction is never reached and the command reports "Forgot" with nothing gone.
final class MemoryForgetCommandTests: XCTestCase {
    func testForgettingAnInstructionsIdAsAFactSaysItIsNotOne() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: ScriptedProvider([]))
        try await s.start(startAPI: false)
        let rule = try await s.memory.addPreference(text: "Keep the VPN connected.", scope: "global", provenance: Provenance(sourceType: .userMessage))
        let client = ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t")

        let asFact = await s.handle(.forgetEntity(MemoryEntityID(rule.id.rawValue)), from: client)
        guard case .error = asFact else { return XCTFail("an instruction's id was taken as a fact: \(asFact)") }
        var active = try await s.store.listPreferences(scopes: nil, includeInactive: false)
        XCTAssertTrue(active.contains { $0.id == rule.id }, "nothing was forgotten yet")

        let asInstruction = await s.handle(.forgetPreference(rule.id), from: client)
        guard case .ok = asInstruction else { return XCTFail("\(asInstruction)") }
        active = try await s.store.listPreferences(scopes: nil, includeInactive: false)
        XCTAssertFalse(active.contains { $0.id == rule.id })
        await s.stop()
    }
}
