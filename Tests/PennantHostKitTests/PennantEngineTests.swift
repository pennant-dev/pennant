import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Coding runs on the Pennant engine: Pennant's own loop on the run's model, with only the coding tools, writing only
/// inside the project, and asking first as Claude Code runs do.
final class PennantEngineTests: XCTestCase {
    var paths: HostPaths!
    var project: String!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
        project = paths.root.appendingPathComponent("app", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try "Hello, wrold\n".write(toFile: project + "/greeting.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service(_ provider: ScriptedProvider, configure: (inout HostConfig) -> Void = { _ in }) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        config.coding = HostConfig.Coding(engine: .pennant, projects: [CodingProject(path: project)])
        configure(&config)
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    /// A coding run as `code` starts one: a thread of its own in the project, on the Pennant engine.
    private func startRun(_ s: HostService, _ request: String, mode: CodingMode? = nil) async throws -> (ConversationID, TaskID) {
        let agents = try await s.store.listAgents(includeRetired: false)
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversation, task) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: request, attachments: [],
                                                                           folder: project, mode: mode, engine: .pennant)
        return (conversation, task)
    }

    private func wait(_ s: HostService, _ id: TaskID, _ state: TaskState) async throws -> TaskRecord {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let t = try await s.store.task(id), t.state == state { return t }
            try await Task.sleep(for: .milliseconds(20))
        }
        let t = try await s.store.task(id)
        XCTFail("task is \(t?.state.rawValue ?? "missing"): \(t?.stateReason ?? "")")
        throw ToolError.timeout
    }

    private func card(_ s: HostService) async throws -> PendingApproval {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let card = try await s.runtime.pendingApprovals().first { return card }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ToolError.failed("no card came up")
    }

    private func greeting() throws -> String { try String(contentsOfFile: project + "/greeting.txt", encoding: .utf8) }

    private func results(_ s: HostService, _ conversation: ConversationID, _ tool: String) async throws -> [ToolResult] {
        let messages = try await s.store.messagesAfter(conversationID: conversation, after: nil, limit: 200)
        return messages.flatMap(\.parts).compactMap { if case .toolResult(let r) = $0, r.name == tool { return r }; return nil }
    }

    // MARK: A run

    func testARunEditsItsProjectRunsCommandsThereAndReportsBack() async throws {
        let provider = ScriptedProvider([])
        provider.codingTurns = [
            .init(toolCalls: [ToolCall(id: ToolCallID("e1"), name: "edit_file", arguments: ["path": "greeting.txt", "old_text": "wrold", "new_text": "world"])]),
            .init(toolCalls: [ToolCall(id: ToolCallID("s1"), name: "shell", arguments: ["command": "pwd; cat greeting.txt"])]),
            .init(text: "Fixed the typo in greeting.txt and read it back."),
        ]
        let s = try await service(provider)
        let (conversation, taskID) = try await startRun(s, "Fix the typo in greeting.txt")
        let done = try await s.runtime.awaitTask(taskID, timeout: 10)

        XCTAssertEqual(done.state, .completed, done.stateReason)
        XCTAssertEqual(done.resultSummary?.trimmingCharacters(in: .whitespaces), "Fixed the typo in greeting.txt and read it back.", "the summary goes back to whoever asked")
        XCTAssertEqual(try greeting(), "Hello, world\n")
        let shells = try await results(s, conversation, "shell")
        let shell = try XCTUnwrap(shells.first)
        XCTAssertTrue(shell.textContent.contains("/app\n") && shell.textContent.contains("Hello, world"), "the shell runs in the project: \(shell.textContent)")
        // It ran on Pennant's loop with only the coding tools, and every model call is in the usage ledger.
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(Set(request.tools.map(\.name)), Set(TaskRuntime.codingTools))
        XCTAssertTrue(request.messages.first?.text.contains("a coding run in the project app (\(project!))") ?? false)
        let usage = try await s.store.usage(from: .distantPast, to: .distantFuture).filter { $0.taskID == taskID }
        XCTAssertEqual(usage.count, 3)
        XCTAssertTrue(usage.allSatisfy { $0.conversationID == conversation })
        let thread = try await s.store.conversation(conversation)
        XCTAssertEqual(thread?.engine, .pennant)
        XCTAssertEqual(thread?.workingDirectory, project)
        await s.stop()
    }

    /// The thread's own model, else the one in the Coding settings, else the host's default.
    func testTheRunsModelIsTheThreadsThenTheCodingSettingThenTheDefault() async throws {
        let fast = InferenceProfile(inference: HostConfig.Inference(model: "fast")), strong = InferenceProfile(inference: HostConfig.Inference(model: "strong"))
        let s = try await service(ScriptedProvider([])) { config in
            config.inferenceProfiles += [fast, strong]
            config.coding?.modelProfileID = fast.id
        }
        let runtime = await s.runtime
        let agents = try await s.store.listAgents(includeRetired: false)
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        var thread = Conversation(agentID: pennant.id)
        thread.engine = .pennant
        var profile = await runtime.codingProfile(pennant, conversation: thread)
        XCTAssertEqual(profile.modelProfileID, fast.id, "the Coding setting")
        let first = await runtime.modelChoices(for: profile).first
        XCTAssertEqual(first?.label, fast.name)
        thread.engineModel = "strong"
        profile = await runtime.codingProfile(pennant, conversation: thread)
        XCTAssertEqual(profile.modelProfileID, strong.id, "the thread's own, by name or id")
        var config = await s.config
        config.coding?.modelProfileID = nil
        await runtime.updateConfig(config)
        thread.engineModel = nil
        profile = await runtime.codingProfile(pennant, conversation: thread)
        XCTAssertNil(profile.modelProfileID, "the host's default")
        // While a plan waits, nothing is written.
        thread.engineMode = .plan
        profile = await runtime.codingProfile(pennant, conversation: thread)
        XCTAssertEqual(profile.toolAllowlist, TaskRuntime.planningTools)
        await s.stop()
    }

    // MARK: Asking first

    func testADeletingCommandWaitsForTheOwnersCard() async throws {
        try FileManager.default.createDirectory(atPath: project + "/build", withIntermediateDirectories: true)
        let provider = ScriptedProvider([])
        provider.codingTurns = [
            .init(toolCalls: [ToolCall(id: ToolCallID("s1"), name: "shell", arguments: ["command": "rm -rf build"])]),
            .init(text: "Left the build folder alone."),
        ]
        let s = try await service(provider)
        let (conversation, taskID) = try await startRun(s, "Clean up")
        let pending = try await card(s)
        XCTAssertEqual(pending.request.title, "Delete: run a command")
        XCTAssertEqual(pending.request.text, "rm -rf build")
        XCTAssertEqual(pending.conversationID, conversation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project + "/build"), "nothing runs before the owner decides")
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: pending.id, verdict: .reject), by: nil)
        _ = try await wait(s, taskID, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project + "/build"))
        let shells = try await results(s, conversation, "shell")
        let refused = try XCTUnwrap(shells.first)
        XCTAssertTrue(refused.isError && refused.textContent.contains("declined"), refused.textContent)
        await s.stop()
    }

    func testAskForEverythingAsksBeforeAnEdit() async throws {
        let provider = ScriptedProvider([])
        provider.codingTurns = [
            .init(toolCalls: [ToolCall(id: ToolCallID("e1"), name: "edit_file", arguments: ["path": "greeting.txt", "old_text": "wrold", "new_text": "world"])]),
            .init(text: "Fixed."),
        ]
        let s = try await service(provider)
        let (_, taskID) = try await startRun(s, "Fix the typo", mode: .manual)
        let pending = try await card(s)
        XCTAssertEqual(pending.request.title, "Edit a file")
        XCTAssertTrue(pending.request.text.hasPrefix(project + "/greeting.txt"), pending.request.text)
        XCTAssertEqual(try greeting(), "Hello, wrold\n", "the edit waits for the card")
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: pending.id, verdict: .approve), by: nil)
        _ = try await wait(s, taskID, .completed)
        XCTAssertEqual(try greeting(), "Hello, world\n")
        await s.stop()
    }

    func testAPlanIsApprovedBeforeAnythingChanges() async throws {
        let provider = ScriptedProvider([])
        provider.codingTurns = [
            .init(text: "Plan: change \"wrold\" to \"world\" in greeting.txt, then read it back."),
            .init(toolCalls: [ToolCall(id: ToolCallID("e1"), name: "edit_file", arguments: ["path": "greeting.txt", "old_text": "wrold", "new_text": "world"])]),
            .init(text: "Done as planned."),
        ]
        let s = try await service(provider)
        let (conversation, taskID) = try await startRun(s, "Fix the typo", mode: .plan)
        let pending = try await card(s)
        XCTAssertEqual(pending.request.title, "Approve the plan")
        XCTAssertTrue(pending.request.text.contains("change \"wrold\" to \"world\""), pending.request.text)
        XCTAssertFalse(provider.requests.first?.tools.contains { $0.name == "edit_file" || $0.name == "write_file" } ?? true, "no writing while planning")
        XCTAssertEqual(try greeting(), "Hello, wrold\n")
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: pending.id, verdict: .approve), by: nil)
        let done = try await wait(s, taskID, .completed)
        XCTAssertEqual(done.resultSummary?.trimmingCharacters(in: .whitespaces), "Done as planned.")
        XCTAssertEqual(try greeting(), "Hello, world\n")
        let thread = try await s.store.conversation(conversation)
        XCTAssertEqual(thread?.engineMode, .acceptEdits, "an approved plan leaves plan mode")
        await s.stop()
    }

    // MARK: Tools in a project

    private func context(_ project: ProjectScope?) -> ToolContext {
        ToolContext(agentID: AgentID(), taskID: TaskID(), conversationID: ConversationID(), store: FakeStore(), desktop: FakeDesktop(),
                    lease: DesktopLease(pauseOnHumanInput: false, desktop: FakeDesktop(), onChange: { _ in }), config: HostConfig(workingDirectory: paths.root.path), project: project)
    }

    func testEditFileChangesOneExactMatchOnly() async throws {
        let edit = EditFileTool(), ctx = context(ProjectScope(folder: project))
        try "one\ntwo\ntwo\n".write(toFile: project + "/list.txt", atomically: true, encoding: .utf8)
        for (old, why) in [("three", "isn't in"), ("two", "appears 2 times")] {
            do {
                _ = try await edit.invoke(["path": "list.txt", "old_text": .string(old), "new_text": "x"], context: ctx)
                XCTFail("\(old) should be refused")
            } catch {
                XCTAssertTrue("\(error)".contains(why), "\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOfFile: project + "/list.txt", encoding: .utf8), "one\ntwo\ntwo\n", "a refused edit changes nothing")
        let done = try await edit.invoke(["path": "list.txt", "old_text": "two\ntwo", "new_text": "two"], context: ctx)
        XCTAssertTrue(done.textContent.contains("line 2"), done.textContent)
        XCTAssertEqual(try String(contentsOfFile: project + "/list.txt", encoding: .utf8), "one\ntwo\n")
    }

    func testARunWritesOnlyInsideItsProject() async throws {
        let ctx = context(ProjectScope(folder: project))
        let outside = paths.root.appendingPathComponent("outside.txt").path
        try "keep".write(toFile: outside, atomically: true, encoding: .utf8)
        // Out of the folder by path, by `..`, and through a link inside it that points out.
        try FileManager.default.createSymbolicLink(atPath: project + "/escape", withDestinationPath: paths.root.path)
        for path in [outside, "../outside.txt", "escape/outside.txt"] {
            do {
                _ = try await EditFileTool().invoke(["path": .string(path), "old_text": "keep", "new_text": "lost"], context: ctx)
                XCTFail("\(path) should be refused")
            } catch {
                XCTAssertTrue("\(error)".contains("outside the project folder"), "\(error)")
            }
            do {
                _ = try await WriteFileTool().invoke(["path": .string(path), "content": "lost"], context: ctx)
                XCTFail("\(path) should be refused")
            } catch {
                XCTAssertTrue("\(error)".contains("outside the project folder"), "\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), "keep")
        // Inside, new folders included, is fine; and outside a coding run nothing is fenced.
        _ = try await WriteFileTool().invoke(["path": "src/new.txt", "content": "made"], context: ctx)
        XCTAssertEqual(try String(contentsOfFile: project + "/src/new.txt", encoding: .utf8), "made")
        _ = try await WriteFileTool().invoke(["path": .string(outside), "content": "anywhere"], context: context(nil))
        XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), "anywhere")
    }

    func testCommandsRunAsTheRunsIdentityWithoutShowingItsToken() async throws {
        let ctx = context(ProjectScope(folder: project, environment: ["GH_TOKEN": "ghs_secret_token_123", "PENNANT_GITHUB_IDENTITY": "example-bot[bot]"]))
        let result = try await ShellTool().invoke(["command": "echo $PENNANT_GITHUB_IDENTITY $GH_TOKEN; cat greeting.txt"], context: ctx)
        XCTAssertTrue(result.textContent.contains("example-bot[bot] [redacted]"), result.textContent)
        XCTAssertFalse(result.textContent.contains("ghs_secret_token_123"))
        XCTAssertTrue(result.textContent.contains("Hello, wrold"), "and in the project folder")
    }
}
