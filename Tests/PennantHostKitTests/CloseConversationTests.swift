import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class CloseConversationTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    func testClosingHidesTheThreadWithoutStoppingItAndActivityReopens() async throws {
        // The agent asks a question, so its task is still open (waiting) when the conversation is closed.
        let provider = ScriptedProvider([.init(toolCalls: [ToolCall(id: ToolCallID("q1"), name: "ask_user", arguments: ["question": "Which one?"])])])
        var config = HostConfig(workingDirectory: paths.root.path)
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let client = ConnectedClient(id: ClientID("t"), displayName: "Tester", platform: "t")
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })

        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Pick one", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, try await s.store.task(taskID)?.state != .waitingForUser { try await Task.sleep(for: .milliseconds(20)) }
        let waiting = try await s.store.task(taskID)?.state
        XCTAssertEqual(waiting, .waitingForUser)

        guard case .ok = await s.handle(.closeConversation(conversationID, closed: true), from: client) else { return XCTFail("close failed") }
        let closed = try await s.store.conversation(conversationID)?.closedAt
        XCTAssertNotNil(closed)
        // Closing stops nothing: the question still waits, so answering it later works.
        try await Task.sleep(for: .milliseconds(200))
        let still = try await s.store.task(taskID)?.state
        XCTAssertEqual(still, .waitingForUser, "a swipe to close must not throw away a question or a card")

        // Answering in it picks it back up.
        _ = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: conversationID, text: "The second one", attachments: [])
        let afterWriting = try await s.store.conversation(conversationID)?.closedAt
        XCTAssertNil(afterWriting)

        guard case .ok = await s.handle(.closeConversation(conversationID, closed: true), from: client) else { return XCTFail("close failed") }
        guard case .ok = await s.handle(.closeConversation(conversationID, closed: false), from: client) else { return XCTFail("reopen failed") }
        let reopened = try await s.store.conversation(conversationID)?.closedAt
        XCTAssertNil(reopened)
        await s.stop()
    }

    func testDeletingRemovesTheThreadAndPruningClosesIdleOnes() async throws {
        let provider = ScriptedProvider([.init(text: "Done."), .init(text: "Done too.")])
        let s = try HostService(paths: paths, config: HostConfig(workingDirectory: paths.root.path), desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let client = ConnectedClient(id: ClientID("t"), displayName: "Tester", platform: "t")
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, keep, t1) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "keep me", attachments: [])
        let (_, gone, t2) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "delete me", attachments: [])
        for t in [t1, t2] {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, try await s.store.task(t)?.state != .completed { try await Task.sleep(for: .milliseconds(20)) }
        }
        guard case .ok = await s.handle(.deleteConversations([gone]), from: client) else { return XCTFail("delete failed") }
        let deleted = try await s.store.conversation(gone)
        XCTAssertNil(deleted)
        let deletedMessages = try await s.store.messagesAfter(conversationID: gone, after: nil, limit: 10)
        XCTAssertTrue(deletedMessages.isEmpty)
        let deletedTask = try await s.store.task(t2)
        XCTAssertNil(deletedTask)

        // Pruning closes only what's been idle long enough.
        guard case .pruned(let none) = await s.handle(.pruneConversations(idleDays: 30), from: client) else { return XCTFail("prune failed") }
        XCTAssertEqual(none, 0)
        let stored = try await s.store.conversation(keep)
        var old = try XCTUnwrap(stored)
        old.updatedAt = Date().addingTimeInterval(-40 * 86400)
        try await s.store.upsertConversation(old)
        guard case .pruned(let one) = await s.handle(.pruneConversations(idleDays: 30), from: client) else { return XCTFail("prune failed") }
        XCTAssertEqual(one, 1)
        let closed = try await s.store.conversation(keep)?.closedAt
        XCTAssertNotNil(closed)
        await s.stop()
    }

    func testClaudeModelsAreDistinctAndNamed() {
        let models = CodingEngine.claudeCode.models
        XCTAssertNil(models.first?.id, "the CLI's default comes first")
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        XCTAssertEqual(CodingEngine.claudeCode.modelTitle("claude-opus-5"), "Opus 5")
        XCTAssertEqual(CodingEngine.claudeCode.modelTitle("claude-opus-5-5[1m]"), "Opus 5.5 · 1M")
        XCTAssertEqual(CodingEngine.claudeCode.modelTitle("opus"), "Opus (newest)", "conversations set to a family alias still read well")
        XCTAssertEqual(CodingEngine.claudeCode.modelTitle("claude-custom-x"), "claude-custom-x")
        XCTAssertEqual(CodingEngine.claudeCode.modelFamilies.map(\.family), ["Fable", "Opus", "Sonnet", "Haiku"])
    }
}

final class DefaultAgentTests: XCTestCase {
    func testANewHostStartsWithPennant() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let s = try HostService(paths: paths, config: HostConfig(workingDirectory: paths.root.path), desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: ScriptedProvider([]))
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        XCTAssertEqual(agents.filter { $0.kind == .persistent }.map(\.name), ["Pennant"])
        await s.stop()
    }
}
