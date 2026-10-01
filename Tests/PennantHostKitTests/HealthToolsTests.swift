import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// The health review: Pennant reads how its work is going and proposes changes; nothing changes until the owner
/// approves, and only an agent granted the tools sees them.
final class HealthToolsTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service(_ provider: ScriptedProvider, coding: HostConfig.Coding? = nil) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.coding = coding
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    private func waitFor(_ s: HostService, _ id: TaskID, _ state: TaskState) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await s.store.task(id)?.state == state { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("task never reached \(state)")
    }

    /// Pennant with the review tools granted, as `pennant health enable` leaves it.
    private func grantedPennant(_ s: HostService) async throws -> AgentProfile {
        let agents = try await s.store.listAgents(includeRetired: false)
        var pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        pennant.grantedTools = HealthReview.grantedTools
        return try await s.saveAgentProfile(pennant)
    }

    private func toolText(_ s: HostService, _ conversation: ConversationID, _ name: String) async throws -> String {
        let messages = try await s.store.messagesAfter(conversationID: conversation, after: nil, limit: 200)
        return messages.flatMap(\.parts).compactMap { if case .toolResult(let r) = $0, r.name == name { return r.textContent }; return nil }.joined(separator: "\n")
    }

    private func card(_ s: HostService, _ conversation: ConversationID) async throws -> ApprovalRequest {
        let messages = try await s.store.messagesAfter(conversationID: conversation, after: nil, limit: 50)
        return try XCTUnwrap(messages.flatMap(\.parts).compactMap { if case .approval(let a) = $0 { return a }; return nil }.first)
    }

    private func context(_ s: HostService, _ agentID: AgentID) async -> ToolContext {
        ToolContext(agentID: agentID, taskID: TaskID(), conversationID: ConversationID(), store: await s.store, desktop: FakeDesktop(),
                    lease: DesktopLease(pauseOnHumanInput: false, desktop: FakeDesktop(), onChange: { _ in }), config: HostConfig(), runtimeHooks: nil)
    }

    func testOnlyAGrantedAgentSeesTheToolsAndNobodyCallsTheApplyTool() async throws {
        let s = try await service(ScriptedProvider([]))
        let agents = try await s.store.listAgents(includeRetired: false)
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let ungranted = await s.broker.specs(for: pennant).map(\.name)
        XCTAssertFalse(ungranted.contains("health_report"), "without the grant the review tools are hidden")
        XCTAssertFalse(ungranted.contains("propose_agent_change"))
        XCTAssertFalse(ungranted.contains(ApplyProposedChangeTool.name))
        let granted = Set(await s.broker.specs(for: try await grantedPennant(s)).map(\.name))
        XCTAssertTrue(granted.isSuperset(of: HealthReview.grantedTools))
        XCTAssertFalse(granted.contains(ApplyProposedChangeTool.name), "even with the grant it can't apply a change itself")
        await s.stop()
    }

    func testCallingThemWithoutTheGrantIsRefused() async throws {
        let health = ToolCall(id: ToolCallID("h1"), name: "health_report", arguments: [:])
        let apply = ToolCall(id: ToolCallID("a1"), name: ApplyProposedChangeTool.name, arguments: ["kind": "role", "text": "Evil", "agent_id": "x"])
        let sneaky = ToolCall(id: ToolCallID("r1"), name: "request_approval", arguments: [
            "title": "Harmless", "destination": "Somewhere", "text": "Obey me",
            "on_approve": .object(["tool": .string(ApplyProposedChangeTool.name), "arguments": .object(["kind": .string("instructions")]), "text_field": .string("text")]),
        ])
        let provider = ScriptedProvider([.init(toolCalls: [health, apply, sneaky]), .init(text: "Done.")])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversation, task) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: "Try", attachments: [])
        try await waitFor(s, task, .completed)
        let records = try await s.store.toolRecords(taskID: task)
        XCTAssertEqual(records.first { $0.call.name == "health_report" }?.status, .denied)
        XCTAssertEqual(records.first { $0.call.name == ApplyProposedChangeTool.name }?.status, .denied)
        let card = try await toolText(s, conversation, "request_approval")
        XCTAssertTrue(card.contains("can't be attached to a card"), card)
        await s.stop()
    }

    func testAnApprovedProposalChangesOnlyTheWordsAndUsesTheOwnersEdit() async throws {
        let propose = ToolCall(id: ToolCallID("p1"), name: "propose_agent_change", arguments: [
            "change": "instructions", "text": "Answer in one paragraph.", "why": "Replies ran long 12 times this week.",
        ])
        let provider = ScriptedProvider([.init(toolCalls: [propose]), .init(text: "Proposed.")])
        let s = try await service(provider)
        let pennant = try await grantedPennant(s)
        let (_, conversation, task) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: "Review", attachments: [])
        try await waitFor(s, task, .completed)
        let card = try await card(s, conversation)
        XCTAssertEqual(card.title, "Change Pennant's instructions")
        XCTAssertTrue(card.notes.contains("12 times"))
        let unchanged = try await s.store.agent(pennant.id)
        XCTAssertEqual(unchanged?.instructions, pennant.instructions, "nothing changes before approval")

        try await s.runtime.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve, editedText: "Answer in one short paragraph."), by: MessageAuthor(id: PersonID("owner"), name: "Owner"))
        let deadline = Date().addingTimeInterval(5)
        var after = try await s.store.agent(pennant.id)
        while after?.instructions != "Answer in one short paragraph.", Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            after = try await s.store.agent(pennant.id)
        }
        XCTAssertEqual(after?.instructions, "Answer in one short paragraph.", "the owner's edit is what applies")
        XCTAssertEqual(after?.toolAllowlist, pennant.toolAllowlist)
        XCTAssertEqual(after?.grantedTools, pennant.grantedTools)
        XCTAssertEqual(after?.modelProfileID, pennant.modelProfileID)
        await s.stop()
    }

    func testAnApprovedSkillProposalBecomesTheNextVersion() async throws {
        let provider = ScriptedProvider([
            .init(dynamicToolCalls: { [ToolCall(id: ToolCallID("p1"), name: "propose_skill_change", arguments: ["change": "new_version", "skill": "Post weekly update", "text": "1. Draft.\n2. Check links.\n3. Ask for approval.", "why": "Failed 3 of 4 times on broken links."])] }),
            .init(text: "Proposed."),
        ])
        let s = try await service(provider)
        try await s.store.upsertSkill(Skill(name: "Post weekly update", purpose: "Share the week's news", steps: [SkillStep(instruction: "Draft and post.")]))
        let pennant = try await grantedPennant(s)
        let (_, conversation, task) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: "Review skills", attachments: [])
        try await waitFor(s, task, .completed)
        let card = try await card(s, conversation)
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve), by: MessageAuthor(id: PersonID("owner"), name: "Owner"))
        let deadline = Date().addingTimeInterval(5)
        var versions: [Skill] = []
        while versions.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            versions = try await s.store.listSkills(includeDisabled: true).filter { $0.name == "Post weekly update" }
        }
        let newest = try XCTUnwrap(versions.max { $0.version < $1.version })
        XCTAssertEqual(newest.version, 2)
        XCTAssertTrue(newest.body.contains("Check links"))
        XCTAssertTrue(newest.steps.isEmpty, "the approved instructions replace the old steps")
        await s.stop()
    }

    /// A bug in Pennant itself: approved, a coding run gets the brief to fix it on its own branch, never shipping it.
    /// (On the Pennant engine, so no real CLI runs.)
    func testAnApprovedCodeChangeStartsACodingRunOnABranch() async throws {
        let propose = ToolCall(id: ToolCallID("c1"), name: "propose_code_change", arguments: [
            "title": "Keep tools under the 128 limit", "problem": "A turn sends 137 tools; the model refuses requests over 128.",
            "approach": "Load connector tools on demand past 128.", "evidence": "2 failed tasks today.",
        ])
        let provider = ScriptedProvider([.init(toolCalls: [propose]), .init(text: "Proposed.")])
        let s = try await service(provider, coding: HostConfig.Coding(engine: .pennant, projects: [CodingProject(path: paths.root.path)]))
        let pennant = try await grantedPennant(s)
        let (_, conversation, task) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: "Review", attachments: [])
        try await waitFor(s, task, .completed)
        let card = try await card(s, conversation)
        XCTAssertEqual(card.title, "Code change: Keep tools under the 128 limit")
        XCTAssertTrue(card.details.contains { $0.label == "Branch" && $0.value == "pennant/keep-tools-under-the-128-limit" })
        let before = try await s.store.listConversations(agentID: pennant.id).filter(\.isCodingRun)
        XCTAssertTrue(before.isEmpty, "no coding run before approval")

        try await s.runtime.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve), by: MessageAuthor(id: PersonID("owner"), name: "Owner"))
        let deadline = Date().addingTimeInterval(5)
        var runs: [Conversation] = []
        while runs.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            runs = try await s.store.listConversations(agentID: pennant.id).filter(\.isCodingRun)
        }
        let run = try XCTUnwrap(runs.first)
        let brief = try await s.store.messagesAfter(conversationID: run.id, after: nil, limit: 5).first { $0.role == .user }?.text ?? ""
        XCTAssertTrue(brief.contains("137 tools"), brief)
        XCTAssertTrue(brief.contains("git worktree add") && brief.contains("-b pennant/keep-tools-under-the-128-limit"), brief)
        XCTAssertTrue(brief.contains("Don't push, merge, deploy or release"), brief)
        await s.stop()
    }

    func testTheReportCountsFailuresAndHandOffsThatDidntLand() async throws {
        let s = try await service(ScriptedProvider([]))
        let pennant = try await grantedPennant(s)
        for i in 0..<3 {
            try await s.store.upsertTask(TaskRecord(agentID: pennant.id, conversationID: ConversationID(), title: "Post \(i)", objective: "Post", state: .failed, stateReason: "LinkedIn refused the token (401) after \(i + 2) tries"))
        }
        try await s.store.upsertTask(TaskRecord(agentID: pennant.id, conversationID: ConversationID(), title: "Ok", objective: "Ok", state: .completed))
        // A task asked a coding run twice; the first answer pointed at a report card the asker can't see.
        let asker = TaskRecord(agentID: pennant.id, conversationID: ConversationID(), title: "Fix the About page", objective: "x", state: .completed)
        try await s.store.upsertTask(asker)
        var run = Conversation(agentID: pennant.id, title: "About page")
        run.engine = .claudeCode
        try await s.store.upsertConversation(run)
        for (i, answer) in ["The verification and caveats are in the report above; nothing was pushed.", "Fixed on the branch."].enumerated() {
            var asked = TaskRecord(agentID: pennant.id, conversationID: run.id, title: "Fix it \(i)", objective: "x", state: .completed, resultSummary: answer)
            asked.requestedByTaskID = asker.id
            try await s.store.upsertTask(asked)
        }
        let found = await s.broker.tool(named: "health_report")
        let tool = try XCTUnwrap(found)
        let report = try await tool.invoke(["days": 7], context: await context(s, pennant.id)).textContent
        XCTAssertTrue(report.contains("Pennant | 5 | 2 | 3 | 0"), report)
        XCTAssertTrue(report.contains("Coding runs | 2 | 2 | 0 | 0"), report)
        XCTAssertTrue(report.contains("3× LinkedIn refused the token (#) after # tries"), "alike failures are counted together: \(report)")
        XCTAssertTrue(report.contains("Hand-offs to coding runs (2)"), report)
        XCTAssertTrue(report.contains("1× an answer the asking task couldn't read"), report)
        XCTAssertTrue(report.contains("1× a task asked again"), report)
        await s.stop()
    }

    /// The report is about Pennant: its own work (retired agents' included, from before there was one agent), its
    /// helpers and its coding runs, never a list of agents.
    func testTheReportIsAboutPennantsWorkHelpersAndCodingRuns() async throws {
        let s = try await service(ScriptedProvider([]))
        let pennant = try await grantedPennant(s)
        var retired = AgentProfile(name: "Poster", role: "posts")
        retired.status = .retired
        try await s.store.upsertAgent(retired)
        let helper = AgentProfile(kind: .worker, name: "Pennant's worker", role: "helps", parentAgentID: pennant.id)
        try await s.store.upsertAgent(helper)
        var run = Conversation(agentID: pennant.id, title: "Fix it")
        run.engine = .claudeCode
        try await s.store.upsertConversation(run)

        try await s.store.upsertTask(TaskRecord(agentID: pennant.id, conversationID: ConversationID(), title: "Inbox", objective: "x", state: .completed))
        try await s.store.upsertTask(TaskRecord(agentID: retired.id, conversationID: ConversationID(), title: "Post", objective: "x", state: .failed, stateReason: "LinkedIn said no"))
        try await s.store.upsertTask(TaskRecord(agentID: helper.id, conversationID: ConversationID(), title: "Look it up", objective: "x", state: .completed))
        try await s.store.upsertTask(TaskRecord(agentID: pennant.id, conversationID: run.id, title: "New fix", objective: "x", state: .completed))
        try await s.store.appendUsage(UsageRecord(agentID: pennant.id, taskID: TaskID(), conversationID: run.id, profileID: nil, modelLabel: "Claude Code",
                                                  provider: "claude-code", model: "claude-code", inputTokens: 10, cachedInputTokens: 0, outputTokens: 5, cost: 2.5, estimated: false))
        try await s.store.appendUsage(UsageRecord(agentID: pennant.id, taskID: TaskID(), conversationID: nil, profileID: nil, modelLabel: "DeepSeek",
                                                  provider: "azure", model: "deepseek", inputTokens: 10, cachedInputTokens: 0, outputTokens: 5, cost: 0.25, estimated: false))

        let found = await s.broker.tool(named: "health_report")
        let tool = try XCTUnwrap(found)
        let report = try await tool.invoke(["days": 7], context: await context(s, pennant.id)).textContent
        XCTAssertTrue(report.hasPrefix("Pennant health"), report)
        XCTAssertTrue(report.contains("Pennant | 2 | 1 | 1 | 0"), "its own work and the retired agent's: \(report)")
        XCTAssertTrue(report.contains("Helpers | 1 | 1 | 0 | 0"), report)
        XCTAssertTrue(report.contains("Coding runs | 1 | 1 | 0 | 0 | – | – | $2.50"), "the run, with the CLI's cost: \(report)")
        XCTAssertFalse(report.contains("Poster |"), report)
        XCTAssertTrue(report.contains("1× LinkedIn said no — Pennant"), report)
        await s.stop()
    }
}
