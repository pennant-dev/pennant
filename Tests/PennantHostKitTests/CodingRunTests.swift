import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Coding runs: Pennant's `code` tool hands a change to the coding engine in a thread of its own, in the project asked
/// for by name, or the default one.
final class CodingRunTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func folder(_ name: String) throws -> String {
        let url = paths.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// `code` starts a coding run in a thread of its own under the one that asked, in the project it named. (On the
    /// Pennant engine with a scripted model, so no real coding CLI runs.)
    func testCodeStartsACodingThreadUnderTheOneThatAskedInTheProjectItNamed() async throws {
        let app = try folder("app"), site = try folder("site")
        let code = ToolCall(id: ToolCallID("c1"), name: "code", arguments: ["request": "Fix the typo in the README", "folder": "SITE"])
        let provider = ScriptedProvider([.init(toolCalls: [code]), .init(text: "Started a coding run.")])
        provider.codingTurns = [.init(text: "There was no typo to fix.")]
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.coding = HostConfig.Coding(engine: .pennant, projects: [CodingProject(path: app), CodingProject(path: site)])
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, asking, taskID) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: "Fix the README typo", attachments: [])
        for _ in 0..<400 where !(try await s.store.task(taskID)?.state.isTerminal ?? false) { try await Task.sleep(for: .milliseconds(20)) }

        // The lead was told which projects there are.
        let leadPrompt = provider.requests.first?.messages.first?.text ?? ""
        XCTAssertTrue(leadPrompt.contains("## Coding projects") && leadPrompt.contains("- site: \(site)"), leadPrompt)
        let threads = try await s.store.listConversations(agentID: pennant.id)
        let run = try XCTUnwrap(threads.first { $0.isCodingRun }, "a coding thread was started")
        XCTAssertEqual(run.parentID, asking, "it sits under the thread that asked")
        XCTAssertEqual(run.agentID, pennant.id)
        XCTAssertEqual(run.engine, .pennant)
        XCTAssertEqual(run.workingDirectory, site, "the project named, whatever its case")
        let runTasks = try await s.store.listTasks(agentID: pennant.id, includeFinished: true).filter { $0.conversationID == run.id }
        XCTAssertEqual(runTasks.first?.requestedByTaskID, taskID)
        await s.stop()
    }

    /// A request names a project, a folder's path, or nothing (the first project); an unknown name says which exist.
    func testARequestFindsItsProjectByNameOrFallsBackToTheDefault() throws {
        let coding = HostConfig.Coding(projects: [CodingProject(path: "/work/app"), CodingProject(name: "Marketing site", path: "/work/www")])
        XCTAssertEqual(try TaskRuntime.projectFolder(nil, in: coding), "/work/app")
        XCTAssertEqual(try TaskRuntime.projectFolder("  ", in: coding), "/work/app")
        XCTAssertEqual(try TaskRuntime.projectFolder("marketing site", in: coding), "/work/www")
        XCTAssertEqual(try TaskRuntime.projectFolder("/work/other", in: coding), "/work/other")
        XCTAssertEqual(try TaskRuntime.projectFolder("~/x", in: coding), (NSHomeDirectory() as NSString).appendingPathComponent("x"))
        XCTAssertThrowsError(try TaskRuntime.projectFolder("blog", in: coding)) { error in
            XCTAssertTrue("\(error)".contains("Projects: app, Marketing site"), "\(error)")
        }
        XCTAssertThrowsError(try TaskRuntime.projectFolder(nil, in: HostConfig.Coding()), "no projects, no default")
    }

    // MARK: The coding allowance

    /// A host whose lead agent can ask for coding runs, with the runs themselves doing nothing (scripted model, no CLI).
    private func host(_ provider: ScriptedProvider, app: String) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.coding = HostConfig.Coding(engine: .pennant, projects: [CodingProject(path: app)])
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    /// A task of the lead agent's own, working (as the chat's turn does), to ask for coding runs from.
    private func askingTask(_ s: HostService) async throws -> (AgentProfile, TaskRecord) {
        let agents = try await s.store.listAgents(includeRetired: false)
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let conversation = Conversation(agentID: pennant.id, title: "Look into the README")
        try await s.store.upsertConversation(conversation)
        let task = TaskRecord(agentID: pennant.id, conversationID: conversation.id, title: "Look into the README", objective: "Look into the README", state: .running)
        try await s.store.upsertTask(task)
        return (pennant, task)
    }

    /// Starts a coding run from a task and waits for it to end, returning the run's task.
    @discardableResult
    private func startRun(_ s: HostService, _ caller: AgentProfile, _ task: TaskRecord, _ request: String = "Look at the README") async throws -> TaskRecord {
        let hooks = await s.runtime.makeHooks(agentID: caller.id, taskID: task.id)
        let (runTask, _) = try await hooks.startCoding(request, nil, nil, nil)
        return try await s.runtime.awaitTask(runTask, timeout: 20)
    }

    /// The four-run cap holds against an automatic retry: the fifth ask is refused, the refusal says so, and no run is
    /// started for it. Nothing but the owner's word buys more.
    func testFourCodingRunsUseUpTheAllowanceAndAFifthIsRefused() async throws {
        let app = try folder("app")
        let provider = ScriptedProvider([])
        provider.codingTurns = Array(repeating: .init(text: "I read the README."), count: 8)
        let s = try await host(provider, app: app)
        let (pennant, task) = try await askingTask(s)
        for _ in 1...TaskRuntime.codingRunsPerAllowance { try await startRun(s, pennant, task) }
        let runs = try await s.store.listTasks(agentID: pennant.id, includeFinished: true).filter { $0.requestedByTaskID == task.id }
        XCTAssertEqual(runs.count, TaskRuntime.codingRunsPerAllowance)

        let hooks = await s.runtime.makeHooks(agentID: pennant.id, taskID: task.id)
        do {
            _ = try await hooks.startCoding("Look at the README again", nil, nil, nil)
            XCTFail("a fifth run started without the owner writing")
        } catch {
            XCTAssertTrue("\(error)".contains("coding runs"), "\(error)")
            XCTAssertTrue("\(error)".contains("owner"), "\(error)")
        }
        let after = try await s.store.listTasks(agentID: pennant.id, includeFinished: true).filter { $0.requestedByTaskID == task.id }
        XCTAssertEqual(after.count, TaskRuntime.codingRunsPerAllowance, "no run was started for the refused ask")
        await s.stop()
    }

    /// The owner's explicit continuation starts a new allowance on the same task (nothing is deleted or recreated), and
    /// each reset is recorded on it. A message Pennant sent itself does not.
    func testAnExplicitOwnerContinuationGrantsAFreshAllowanceWithoutRecreatingTheTask() async throws {
        let app = try folder("app")
        let provider = ScriptedProvider([])
        provider.codingTurns = Array(repeating: .init(text: "I read the README."), count: 20)
        let s = try await host(provider, app: app)
        let (pennant, task) = try await askingTask(s)
        for _ in 1...TaskRuntime.codingRunsPerAllowance { try await startRun(s, pennant, task) }
        let hooks = await s.runtime.makeHooks(agentID: pennant.id, taskID: task.id)
        do {
            _ = try await hooks.startCoding("Once more", nil, nil, nil)
            XCTFail("capped before the owner writes")
        } catch {
            XCTAssertTrue("\(error)".contains("coding runs"), "\(error)")
        }

        // The owner writes in the same conversation: the same task is continued, with a new allowance.
        let (_, conversation, continued) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: task.conversationID, text: "Go on, look at the rest",
                                                                                 attachments: [], author: MessageAuthor(id: PersonID("owner"), name: "Maya"))
        XCTAssertEqual(continued, task.id, "the same task, not a new one")
        XCTAssertEqual(conversation, task.conversationID)
        let stored = try await s.store.task(task.id)
        let continuedTask = try XCTUnwrap(stored)
        XCTAssertEqual(continuedTask.codingAllowanceResets, 1, "the reset is recorded on the task")
        XCTAssertNotNil(continuedTask.codingAllowanceResetAt)

        // A fresh allowance of the same size, on the same task.
        for _ in 1...TaskRuntime.codingRunsPerAllowance { try await startRun(s, pennant, continuedTask) }
        let runs = try await s.store.listTasks(agentID: pennant.id, includeFinished: true).filter { $0.requestedByTaskID == task.id }
        XCTAssertEqual(runs.count, TaskRuntime.codingRunsPerAllowance * 2, "four more were allowed on the same task")
        let again = await s.runtime.makeHooks(agentID: pennant.id, taskID: task.id)
        do {
            _ = try await again.startCoding("Once more", nil, nil, nil)
            XCTFail("the new allowance is bounded too")
        } catch {
            XCTAssertTrue("\(error)".contains("coding runs"), "\(error)")
        }
        let finalTask = try await s.store.task(task.id)
        XCTAssertNotNil(finalTask?.codingAllowanceResetAt, "still one task, still the owner's continuation")
        XCTAssertEqual(finalTask?.codingAllowanceResets, 1)
        await s.stop()
    }

    /// The owner's word is the owner's or a teammate's. Pennant's own messages, a message with no author (a scheduled
    /// run's kick-off, a card's decision, a helper's report) and a contact writing over Teams or iMessage don't reset it.
    func testOnlyTheOwnersWordResetsTheAllowance() async throws {
        let s = try await host(ScriptedProvider([]), app: try folder("app"))
        try await s.people.invite("dana@harbor.test")
        let invites = await s.people.snapshot().invites
        let code = try XCTUnwrap(invites.first?.code)
        let dana = try await s.people.redeem(code: code, name: "Dana Ortiz", password: "harbor-dana-test", trusted: true)
        let theirs = [MessageAuthor(id: PersonID("owner"), name: "Maya"), MessageAuthor(id: dana.id, name: dana.name)]
        let notTheirs: [MessageAuthor?] = [nil, MessageAuthor(id: PersonID("pennant"), name: "Pennant"),
                                           MessageAuthor(id: PersonID("contact:harbor-ops"), name: "Harbor ops"), MessageAuthor(id: PersonID("teams:aad-7"), name: "Jonas")]
        for author in theirs {
            let counts = await s.runtime.continuedByOwner(author)
            XCTAssertTrue(counts, "\(author)")
        }
        for author in notTheirs {
            let counts = await s.runtime.continuedByOwner(author)
            XCTAssertFalse(counts, "\(String(describing: author))")
        }
        await s.stop()
    }

    /// The chat steering a thread that's still going passes on the owner's word only when its own turn is theirs. Sent
    /// on its own (a heartbeat, a thread's report), it doesn't buy the thread more coding runs.
    func testTheChatSteeringAThreadResetsItsAllowanceOnlyOnTheOwnersWord() async throws {
        let s = try await host(ScriptedProvider([]), app: try folder("app"))
        let (pennant, thread) = try await askingTask(s)
        let chat = Conversation(agentID: pennant.id, title: "Check-in")
        try await s.store.upsertConversation(chat)
        let turn = TaskRecord(agentID: pennant.id, conversationID: chat.id, title: "Check-in", objective: "Check in on the work", state: .running)
        try await s.store.upsertTask(turn)
        try await s.store.appendMessage(Message(conversationID: chat.id, agentID: pennant.id, taskID: turn.id, role: .user, parts: [.text("Check in on the work")]))

        _ = try await s.runtime.messageThread(from: turn.id, thread: thread.conversationID.rawValue, text: "Keep going")
        let unasked = try await s.store.task(thread.id)
        XCTAssertNil(unasked?.codingAllowanceResets, "the chat on its own")

        try await s.store.appendMessage(Message(conversationID: chat.id, agentID: pennant.id, taskID: turn.id, role: .user, parts: [.text("Tell it to finish the README")],
                                                author: MessageAuthor(id: PersonID("owner"), name: "Maya")))
        _ = try await s.runtime.messageThread(from: turn.id, thread: thread.conversationID.rawValue, text: "Finish the README")
        let asked = try await s.store.task(thread.id)
        XCTAssertEqual(asked?.codingAllowanceResets, 1, "passed on from Maya")
        await s.stop()
    }

    // MARK: Whether a run changed anything

    /// A run the code tool asked for that only read completes (so apps from before the flag still read it), marked as
    /// having changed nothing, and its words go back as what it found rather than as a change made.
    func testARunThatOnlyReadCompletesMarkedAsChangingNothing() async throws {
        let provider = ScriptedProvider([])
        provider.codingTurns = [.init(text: "I read the README. The typo is on line 3; I'd fix it next.")]
        let s = try await host(provider, app: try folder("app"))
        let (pennant, task) = try await askingTask(s)
        let run = try await startRun(s, pennant, task)
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.madeChanges, false)
        XCTAssertTrue(TaskRuntime.stateWords(run).hasPrefix("ended without changing anything"), TaskRuntime.stateWords(run))
        await s.stop()
    }

    /// A run that writes a file changed its project.
    func testARunThatWritesAFileIsMarkedAsChangingItsProject() async throws {
        let app = try folder("app")
        let provider = ScriptedProvider([])
        provider.codingTurns = [
            .init(toolCalls: [ToolCall(id: ToolCallID("w1"), name: "write_file", arguments: ["path": "NOTES.md", "content": "Harbor launch notes"])]),
            .init(text: "Added NOTES.md."),
        ]
        let s = try await host(provider, app: app)
        let (pennant, task) = try await askingTask(s)
        let run = try await startRun(s, pennant, task, "Add launch notes")
        XCTAssertEqual(run.state, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app + "/NOTES.md"))
        XCTAssertEqual(run.madeChanges, true)
        XCTAssertTrue(TaskRuntime.stateWords(run).hasPrefix("done"), TaskRuntime.stateWords(run))
        await s.stop()
    }

    /// The owner's own coding thread isn't judged: a question or a review there changes nothing on purpose.
    func testTheOwnersOwnCodingThreadIsNotJudged() async throws {
        let app = try folder("app")
        let provider = ScriptedProvider([])
        provider.codingTurns = [.init(text: "The README explains how to run Harbor locally.")]
        let s = try await host(provider, app: app)
        let agents = try await s.store.listAgents(includeRetired: false)
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, id) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: "What does the README say?", attachments: [],
                                                              author: MessageAuthor(id: PersonID("owner"), name: "Maya"), folder: app, engine: .pennant)
        let run = try await s.runtime.awaitTask(id, timeout: 20)
        XCTAssertEqual(run.state, .completed)
        XCTAssertNil(run.madeChanges)
        await s.stop()
    }

    /// Git's view of a project sees another edit to a file that was already changed, a new file in a folder git
    /// already lists as new, and an edit to a new file: what `git status` alone shows the same before and after.
    func testGitStateSeesEditsToFilesThatWereAlreadyChanged() async throws {
        let repo = try folder("repo")
        let setup = try await ShellRunner.run("git init -q && echo a > README.md && git add . && git -c user.name=Maya -c user.email=maya@harbor.test commit -qm init && echo b >> README.md && mkdir docs && echo one > docs/one.md",
                                              workingDirectory: repo, timeout: 30)
        XCTAssertEqual(setup.exitCode, 0, setup.stdout)
        func state() async throws -> String {
            let state = await TaskRuntime.gitState(of: repo)
            return try XCTUnwrap(state)
        }
        let start = try await state()
        let unchanged = try await state()
        XCTAssertEqual(start, unchanged, "nothing changed")
        try "a\nb\nc\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        let edited = try await state()
        XCTAssertNotEqual(start, edited, "another edit to a changed file")
        try "two".write(toFile: repo + "/docs/two.md", atomically: true, encoding: .utf8)
        let added = try await state()
        XCTAssertNotEqual(edited, added, "a new file in a new folder")
        try "uno".write(toFile: repo + "/docs/one.md", atomically: true, encoding: .utf8)
        let rewritten = try await state()
        XCTAssertNotEqual(added, rewritten, "an edit to a new file")
        let plain = await TaskRuntime.gitState(of: try folder("plain"))
        XCTAssertNil(plain, "not a repository")
    }
}
