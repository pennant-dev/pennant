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
        // The system prompt, then the task in the message after it: the inspector shows both as the prompt.
        let sent = provider.requests.first?.messages.prefix(2).map(\.text).joined(separator: "\n") ?? ""
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
        XCTAssertFalse(preview.systemPrompt.contains(ContextBuilder.workingAlongsideRules), "the chat hands the web and the Mac to threads")
        await s.stop()
    }

    /// A thread is told to use its own Chrome tabs and apps in the background before the owner's pointer and screen.
    func testThreadsAreToldToWorkWithoutTakingOverTheMac() async throws {
        let s = try await service(ScriptedProvider([]))
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let task = TaskRecord(agentID: agent.id, conversationID: ConversationID(), title: "Sign up", objective: "Sign Harbor up for the newsletter")
        let specs = try await s.runtime.turnSpecs(task: task, agent: agent)
        XCTAssertTrue(specs.contains { $0.name == "web_open" } && specs.contains { $0.name == "app_click" })
        let output = await ContextBuilder().build(
            ContextBuilder.Input(agent: agent, task: task, config: HostConfig(), preferences: [], memoryHits: [], skills: [], checkpoint: nil, messages: [], toolSpecs: specs, desktopStatus: DesktopStatus(), runtimeNotes: [], artifactLoader: { _ in nil }),
            estimator: { _, _ in 0 }
        )
        let prompt = output.messages.first?.text ?? ""
        XCTAssertTrue(prompt.contains("## Using the Mac and the web without taking them over"))
        let web = try XCTUnwrap(prompt.range(of: "1. On the web")), apps = try XCTUnwrap(prompt.range(of: "2. In a Mac app")), last = try XCTUnwrap(prompt.range(of: "3. Only when the app_ tools can't do it"))
        XCTAssertTrue(web.lowerBound < apps.lowerBound && apps.lowerBound < last.lowerBound)
        // ui_action and ui_set_value use the owner's screen, so they're with the last resort, not the background tools.
        XCTAssertTrue(prompt.contains("screenshot, click, type_text, ui_action and ui_set_value"), prompt)
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

    /// Two tasks in one conversation start with the same system prompt: their objectives and the checkpoint come in
    /// the message after it, so a new task's first call can still come from the provider's prompt cache.
    func testSystemPromptIsTheSameFromTaskToTask() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let provider = ScriptedProvider([.init(text: "Sure."), .init(text: "Done.")])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversation, first) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Find Maya's venue shortlist", attachments: [])
        var deadline = Date().addingTimeInterval(8)
        while Date() < deadline, try await s.store.task(first)?.state != .completed { try await Task.sleep(for: .milliseconds(20)) }
        let (_, _, second) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: conversation, text: "Now book the Harbor room", attachments: [])
        deadline = Date().addingTimeInterval(8)
        while Date() < deadline, try await s.store.task(second)?.state != .completed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(provider.requests.count, 2)
        let a = provider.requests[0].messages, b = provider.requests[1].messages
        XCTAssertEqual(a[0].text, b[0].text, "identical system prompt for both tasks")
        XCTAssertFalse(a[0].text.contains("Find Maya's venue shortlist"))
        XCTAssertTrue(a[1].text.hasPrefix("## Current task") && a[1].text.contains("Find Maya's venue shortlist"))
        XCTAssertTrue(b[1].text.contains("Now book the Harbor room"))
        await s.stop()
    }

    /// What a model wrote next to its tool calls goes back shortened: read back in full on every step, it's copied, and
    /// a step that narrates takes many times longer.
    func testNarrationNextToToolCallsIsReplayedShort() async throws {
        let agent = AgentProfile(name: "Pennant", role: "personal agent")
        let task = TaskRecord(agentID: agent.id, conversationID: ConversationID(), title: "Venue", objective: "Find a venue")
        let musing = "They asked about the venue. Should I search mail or the web first? " + String(repeating: "Let me weigh that again. ", count: 200)
        let call = ToolCall(id: ToolCallID("c1"), name: "list_directory", arguments: ["path": .string("/tmp")])
        let earlier = TaskID()
        let messages = [
            Message(conversationID: task.conversationID, agentID: agent.id, taskID: earlier, role: .user, parts: [.text("Is the venue booked?")]),
            Message(conversationID: task.conversationID, agentID: agent.id, taskID: earlier, role: .assistant, parts: [.text("The user asks about the venue. Let me check."), .toolCall(ToolCall(id: ToolCallID("c0"), name: "list_directory", arguments: ["path": .string("/tmp")]))]),
            Message(conversationID: task.conversationID, agentID: agent.id, taskID: earlier, role: .tool, parts: [.toolResult(ToolResult(callID: ToolCallID("c0"), name: "list_directory", content: [.text("booking.pdf")]))]),
            Message(conversationID: task.conversationID, agentID: agent.id, taskID: earlier, role: .assistant, parts: [.text("Yes, it's booked.")]),
            Message(conversationID: task.conversationID, agentID: agent.id, taskID: task.id, role: .user, parts: [.text("Find a venue")]),
            Message(conversationID: task.conversationID, agentID: agent.id, taskID: task.id, role: .assistant, parts: [.text(musing), .toolCall(call)]),
            Message(conversationID: task.conversationID, agentID: agent.id, taskID: task.id, role: .tool, parts: [.toolResult(ToolResult(callID: call.id, name: call.name, content: [.text("venues.txt")]))]),
            Message(conversationID: task.conversationID, agentID: agent.id, taskID: task.id, role: .assistant, parts: [.text(musing)]),
        ]
        let builder = ContextBuilder()
        let output = await builder.build(
            ContextBuilder.Input(agent: agent, task: task, config: HostConfig(), preferences: [], memoryHits: [], skills: [], checkpoint: nil, messages: messages, toolSpecs: [], desktopStatus: DesktopStatus(), runtimeNotes: [], artifactLoader: { _ in nil }),
            estimator: { _, _ in 0 }
        )
        let said = output.messages.filter { $0.role == .assistant }
        XCTAssertEqual(said.count, 4)
        XCTAssertEqual(said[0].text, "", "an earlier task's narration doesn't go back")
        XCTAssertEqual(said[0].toolCalls.count, 1, "its calls do")
        XCTAssertEqual(said[1].text, "Yes, it's booked.", "nor does it lose its reply")
        XCTAssertLessThanOrEqual(said[2].text.count, builder.maxNarrationChars + 2, "this task's narration next to a tool call is cut")
        XCTAssertTrue(said[2].text.hasSuffix(" …") && said[2].toolCalls.count == 1)
        XCTAssertEqual(said[3].text, musing, "a reply without tool calls goes back whole")
        XCTAssertTrue(output.messages[0].text.contains("## Working quietly"))
    }
}
