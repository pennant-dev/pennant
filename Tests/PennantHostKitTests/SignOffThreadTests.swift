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

    /// After the owner approves a card, a send with its approval id and the approved text goes ahead without a second card,
    /// once. Different text, a second send, or a made-up id each ask.
    func testAnApprovalIdExcusesOnlyTheApprovedSendOnce() async throws {
        final class Post: Tool, @unchecked Sendable {
            let lock = NSLock()
            var sent: [String] = []
            var spec: ToolSpec { ToolSpec(name: "linkedin__create_post", description: "[LinkedIn] Post", inputSchema: JSONSchema.object(["text": JSONSchema.string("")]), isConsequential: true, source: "mcp:li") }
            func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
                lock.withLock { sent.append(arguments.string("text") ?? "") }
                return .text(ToolCallID("pending"), name: spec.name, "Posted.")
            }
        }
        actor Box { var id = ""; func set(_ v: String) { id = v } }
        let box = Box()
        let approved = "Harbor 2.0 is live: faster syncs and a new dashboard."
        func post(_ id: String, _ text: String, card: @escaping @Sendable () async -> String) -> ScriptedProvider.Turn {
            .init(dynamicToolCalls: { [ToolCall(id: ToolCallID(id), name: "linkedin__create_post", arguments: ["text": .string(text), "approval_id": .string(await card())])] })
        }
        let ask = ToolCall(id: ToolCallID("ask"), name: "request_approval", arguments: ["title": "LinkedIn post: Harbor 2.0", "destination": "LinkedIn", "text": .string(approved)])
        let s = try await service(ScriptedProvider([
            .init(toolCalls: [ask]),
            post("changed", approved + " Sign up today!", card: { await box.id }),
            post("ok", "  Harbor 2.0 is live:\nfaster syncs and a new dashboard. ", card: { await box.id }),
            post("again", approved, card: { await box.id }),
            post("forged", approved, card: { "made-up" }),
            .init(text: "Done."),
        ]))
        let tool = Post()
        await s.broker.register(tool)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Post the launch", attachments: [])

        let first = try await card(s)
        await box.set(first.id)
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: first.id, verdict: .approve), by: nil)
        var seen: Set<String> = [first.id]
        // Different text, the second send, the made-up id: each asks.
        for expected in ["Sign up today!", approved, approved] {
            let next = try await card(s, excluding: seen)
            XCTAssertTrue(next.request.text.contains(expected), next.request.text)
            seen.insert(next.id)
            try await s.runtime.decideApproval(ApprovalDecision(approvalID: next.id, verdict: .reject), by: nil)
        }

        let deadline = Date().addingTimeInterval(8)
        while try await s.store.task(task)?.state != .completed, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let records = try await s.store.toolRecords(taskID: task)
        func status(_ id: String) -> ToolOutcomeStatus? { records.first { $0.call.id == ToolCallID(id) }?.status }
        XCTAssertEqual(status("changed"), .denied)
        XCTAssertEqual(status("ok"), .succeeded, "the approved send needs no second card")
        XCTAssertEqual(status("again"), .denied)
        XCTAssertEqual(status("forged"), .denied)
        XCTAssertEqual(tool.lock.withLock { tool.sent.count }, 1)
        await s.stop()
    }

    /// A model that keeps calling what's refused stops after three such steps, and says so, instead of spinning until
    /// its budget runs out.
    func testStepsThatAreAllRefusedEndTheWork() async throws {
        struct Proposal: Tool {
            var spec: ToolSpec { ToolSpec(name: "apply_change", description: "d", inputSchema: JSONSchema.object([:]), access: .approvalOnly) }
            func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult { .text(ToolCallID("pending"), name: spec.name, "applied") }
        }
        let calls = (1 ... 6).map { ScriptedProvider.Turn(toolCalls: [ToolCall(id: ToolCallID("p\($0)"), name: "apply_change", arguments: [:])]) }
        let s = try await service(ScriptedProvider(calls + [.init(text: "Done.")]))
        await s.broker.register(Proposal())
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversation, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Apply it", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while try await s.store.task(task)?.state != .completed, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let records = try await s.store.toolRecords(taskID: task)
        XCTAssertEqual(records.count, TaskRuntime.refusedStepLimit, "it stops after three refused steps")
        XCTAssertTrue(records.allSatisfy { $0.status == .denied })
        let messages = try await s.store.messagesAfter(conversationID: conversation, after: nil, limit: 100)
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.text == TaskRuntime.refusedStopNote }, "the owner hears why")
        await s.stop()
    }

    /// A tool that changes something the rules wouldn't catch (a plugin's "restart an app") asks every time, even
    /// right after the owner approved the same call.
    func testAnAsksFirstToolAsksEveryTime() async throws {
        struct Restart: Tool {
            let ran: Counter
            var spec: ToolSpec { ToolSpec(name: "cloud__restart_app", description: "[Cloud] Restart an app", inputSchema: JSONSchema.object(["app": JSONSchema.string("")]),
                                          isConsequential: true, source: "plugin:dev.example.cloud", asksFirst: true) }
            func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
                await ran.add()
                return .text(ToolCallID("pending"), name: spec.name, "Restarting \(arguments.string("app") ?? "?").")
            }
        }
        actor Counter { var n = 0; func add() { n += 1 } }
        func restart(_ id: String) -> ToolCall { ToolCall(id: ToolCallID(id), name: "cloud__restart_app", arguments: ["app": "web", "approval_id": "made-up"]) }
        let s = try await service(ScriptedProvider([.init(toolCalls: [restart("a1")]), .init(toolCalls: [restart("a2")]), .init(text: "Done.")]))
        let ran = Counter()
        await s.broker.register(Restart(ran: ran))
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Restart the web app", attachments: [])

        let first = try await card(s)
        XCTAssertTrue(first.request.title.hasPrefix(SignOff.Reason.changes.title), first.request.title)
        XCTAssertEqual(first.request.destination, "dev.example.cloud")
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: first.id, verdict: .approve), by: nil)
        let second = try await card(s, excluding: [first.id])
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: second.id, verdict: .reject), by: nil)

        let deadline = Date().addingTimeInterval(8)
        while try await s.store.task(task)?.state != .completed, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let records = try await s.store.toolRecords(taskID: task)
        XCTAssertEqual(records.first { $0.call.id == ToolCallID("a1") }?.status, .succeeded)
        XCTAssertEqual(records.first { $0.call.id == ToolCallID("a2") }?.status, .denied)
        let runs = await ran.n
        XCTAssertEqual(runs, 1)
        await s.stop()
    }
}
