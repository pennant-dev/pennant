import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class PromptInspectionTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service(_ provider: ScriptedProvider, rules: String? = nil) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        config.houseRules = rules
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    func testSectionsSplitAtHeadings() {
        let sections = TaskRuntime.sections(of: "You are Pennant.\n\n## How to work\n- a\n- b\n\n## Environment\n- Date: now\n")
        XCTAssertEqual(sections.map(\.title), ["Identity and the agent's own instructions", "How to work", "Environment"])
        XCTAssertTrue(sections[1].text.contains("- b"))
        XCTAssertGreaterThan(sections[1].tokens, 0)
        XCTAssertEqual(sections.map(\.text).joined(), "You are Pennant.\n\n## How to work\n- a\n- b\n\n## Environment\n- Date: now\n\n")
    }

    func testPreviewBeforeTheFirstTurnThenTheRealTurn() async throws {
        let provider = ScriptedProvider([.init(text: "Hello.")])
        let s = try await service(provider, rules: "- Always answer in one sentence.")
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })

        let preview = try await s.runtime.inspectPrompt(agent.id)
        XCTAssertTrue(preview.isPreview)
        let rules = try XCTUnwrap(preview.sections.first { $0.title == "How to work" })
        XCTAssertTrue(rules.text.contains("Always answer in one sentence."))
        XCTAssertFalse(rules.text.contains("Finish the whole task"), "custom rules replace the default")
        XCTAssertTrue(preview.tools.contains { $0.name == "shell" && $0.service == "Built in" })

        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Hi", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, try await s.store.task(taskID)?.state != .completed { try await Task.sleep(for: .milliseconds(20)) }
        let turn = try await s.runtime.inspectPrompt(agent.id)
        XCTAssertFalse(turn.isPreview)
        XCTAssertEqual(turn.historyMessages, 1)
        let sent = provider.requests.first?.messages.first?.text ?? ""
        XCTAssertEqual(turn.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines), sent.trimmingCharacters(in: .whitespacesAndNewlines), "the inspector shows the prompt the model received")
        await s.stop()
    }

    func testDefaultRulesWhenUnset() async throws {
        let provider = ScriptedProvider([])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first)
        let preview = try await s.runtime.inspectPrompt(agent.id)
        XCTAssertTrue(preview.systemPrompt.contains(HouseRules.default))
        await s.stop()
    }
}

final class PromptCacheStabilityTests: XCTestCase {
    /// Two turns of the same task send the same system prompt, so providers can serve it from their prompt cache;
    /// the time and budget ride in the context note at the end.
    func testSystemPromptDoesNotChangeBetweenTurns() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let provider = ScriptedProvider([.init(toolCalls: [ToolCall(id: ToolCallID("c1"), name: "list_directory", arguments: ["path": .string(paths.root.path)])]), .init(text: "Done.")])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "List the folder", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, try await s.store.task(taskID)?.state != .completed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(provider.requests.count, 2)
        let first = provider.requests[0].messages, second = provider.requests[1].messages
        XCTAssertEqual(first.first?.text, second.first?.text, "identical system prompt on every call")
        XCTAssertFalse(first.first?.text.contains("Budget: step") ?? true)
        XCTAssertTrue(second.last?.text.hasPrefix("[Context for this turn]") ?? false)
        XCTAssertTrue(second.last?.text.contains("Budget: step 1/") ?? false)
        // Everything before the note in the second request extends the first request's messages (a stable prefix).
        let prefix = Array(second.dropLast().prefix(first.count - 1)).map(\.text)
        XCTAssertEqual(prefix, Array(first.dropLast()).map(\.text))
        await s.stop()
    }
}
