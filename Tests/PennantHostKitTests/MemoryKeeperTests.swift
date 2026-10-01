import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Memory keeps itself current: a claim that disagrees with the record is settled by judgement, logged, and can be
/// undone. Nothing waits for the owner to review.
final class MemoryKeeperTests: XCTestCase {
    var paths: HostPaths!
    var store: SQLiteStore!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
        store = try SQLiteStore(paths: paths)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private let told = Provenance(sourceType: .userMessage, note: "test")
    private let found = Provenance(sourceType: .toolObservation, note: "found in the deploy log")

    /// A record and a newer claim about it, so there's one contradiction to settle.
    private func contradiction(_ memory: MemoryService) async throws -> MemoryConflict {
        try await memory.assertEntity(kind: .project, name: "Harbor release", summary: "Prod runs 0.1.14", scope: "shared", status: .asserted, provenance: told)
        let claim = try await memory.assertEntity(kind: .project, name: "Harbor release", summary: "Prod runs 0.1.15", scope: "shared", status: .inferred, provenance: found)
        XCTAssertEqual(claim.status, .contradicted)
        let open = try await memory.conflicts()
        return try XCTUnwrap(open.first)
    }

    func testANewerClaimThatReflectsAChangeReplacesTheRecordAndCanBeUndone() async throws {
        let memory = MemoryService(store: store, eventBus: EventBus())
        let c = try await contradiction(memory)
        let prompts = Locked<[String]>([])
        let done = await memory.tend { messages in
            prompts.set(messages.map(\.text))
            return #"{"decision":"take_new","reason":"The 0.1.15 release shipped to prod on Sep 27."}"#
        }
        XCTAssertEqual(done.map(\.action), [.updated])
        XCTAssertTrue(prompts.get().joined().contains("Prod runs 0.1.14") && prompts.get().joined().contains("Prod runs 0.1.15"), "the model sees both")
        let open = try await memory.conflicts()
        XCTAssertTrue(open.isEmpty, "nothing left to review")
        let now = try await store.entity(c.claim.id)
        XCTAssertEqual(now?.status, .inferred)
        let old = try await store.entity(c.current.id)
        XCTAssertEqual(old?.status, .superseded)

        var log = await memory.upkeepLog()
        XCTAssertEqual(log.first?.reason, "The 0.1.15 release shipped to prod on Sep 27.")
        log = try await memory.undoUpkeep(try XCTUnwrap(log.first).id)
        XCTAssertEqual(log.first?.undone, true)
        let restored = try await store.entity(c.current.id)
        XCTAssertEqual(restored?.status, .asserted, "undo puts the record back")
    }

    func testAMisreadingIsSetAsideAndACompatibleClaimIsCombined() async throws {
        let memory = MemoryService(store: store, eventBus: EventBus())
        let c = try await contradiction(memory)
        _ = await memory.tend { _ in #"{"decision":"keep","reason":"The log was about stage, not prod."}"# }
        let claim = try await store.entity(c.claim.id)
        XCTAssertEqual(claim?.status, .superseded)
        let current = try await store.entity(c.current.id)
        XCTAssertEqual(current?.status, .asserted)

        try await memory.assertEntity(kind: .person, name: "Saamer Saad", summary: "Co-founder", scope: "shared", status: .asserted, provenance: told)
        try await memory.assertEntity(kind: .person, name: "Saamer Saad", summary: "Co-founder, owns the frontend", scope: "shared", status: .inferred, provenance: found)
        let done = await memory.tend { _ in #"{"decision":"combine","summary":"Co-founder; owns the frontend.","attributes":{"role":"co-founder"},"reason":"Adds what he owns."}"# }
        XCTAssertEqual(done.map(\.action), [.combined])
        let people = try await store.findEntities(name: "Saamer Saad", kind: .person, scopes: ["shared"])
        let live = people.filter { $0.status == .asserted || $0.status == .inferred }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.summary, "Co-founder; owns the frontend.")
    }

    func testAnUnreadableAnswerLeavesItForTheNextPass() async throws {
        let memory = MemoryService(store: store, eventBus: EventBus())
        _ = try await contradiction(memory)
        let done = await memory.tend { _ in "I'm not sure." }
        XCTAssertTrue(done.isEmpty)
        let open = try await memory.conflicts()
        XCTAssertEqual(open.count, 1)
    }
}
