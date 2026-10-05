import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Once the owner signs off on a delete in a thread, later deletes in the same place there go ahead; anywhere else
/// still asks.
final class SignOffThreadTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service(_ provider: ScriptedProvider) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    private func card(_ s: HostService, excluding seen: Set<String> = []) async throws -> PendingApproval {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let card = try await s.runtime.pendingApprovals().first(where: { !seen.contains($0.id) }) { return card }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw XCTSkip("no card came")
    }

    func testAllowingDeletesHereLetsLaterOnesInTheSamePlaceGoAhead() async throws {
        // Paths that don't exist, outside any temporary folder: `rm -f` succeeds and nothing is touched.
        func rm(_ id: String, _ command: String) -> ToolCall { ToolCall(id: ToolCallID(id), name: "shell", arguments: ["command": .string(command)]) }
        let calls = [rm("r1", "rm -f /pennant-sign-off-test/out/a.png"), rm("r2", "rm -f /pennant-sign-off-test/out/b.png"),
                     rm("r3", "rm -f /pennant-sign-off-test/out/c.png /pennant-sign-off-test/out/d.png"), rm("r4", "rm -f /pennant-sign-off-test/other/e.png")]
        let s = try await service(ScriptedProvider(calls.map { .init(toolCalls: [$0]) } + [.init(text: "Done.")]))
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Tidy the renders", attachments: [])

        // Approve: just this one.
        let first = try await card(s)
        XCTAssertTrue(first.request.text.contains("a.png"), first.request.text)
        XCTAssertEqual(first.request.allowRestLabel, SignOff.allowHereLabel)
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: first.id, verdict: .approve), by: nil)
        // So the next one in the same folder asks; allow deletes there for the thread.
        let second = try await card(s, excluding: [first.id])
        XCTAssertTrue(second.request.text.contains("b.png"), second.request.text)
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: second.id, verdict: .approveRest), by: nil)
        // The third, in the same folder, goes ahead; the fourth, elsewhere, asks.
        let fourth = try await card(s, excluding: [first.id, second.id])
        XCTAssertTrue(fourth.request.text.contains("other/e.png"), fourth.request.text)
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: fourth.id, verdict: .reject), by: nil)

        let deadline = Date().addingTimeInterval(8)
        while try await s.store.task(task)?.state != .completed, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let records = try await s.store.toolRecords(taskID: task)
        func status(_ id: String) -> ToolOutcomeStatus? { records.first { $0.call.id == ToolCallID(id) }?.status }
        XCTAssertEqual(status("r1"), .succeeded)
        XCTAssertEqual(status("r2"), .succeeded)
        XCTAssertEqual(status("r3"), .succeeded, "same folder, allowed for the thread")
        XCTAssertEqual(status("r4"), .denied)
        await s.stop()
    }
}
