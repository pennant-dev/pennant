import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Claude Code's skills linked into Pennant: which files count, keeping in step with them, and handing the ones that need
/// Claude Code to a Claude Code run.
final class ClaudeCodeSkillsTests: XCTestCase {
    private var home: URL!
    private var paths: HostPaths!
    private var store: SQLiteStore!
    private let bus = EventBus()

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cc-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
        store = try SQLiteStore(paths: paths)
    }

    override func tearDown() async throws {
        await store?.close()
        if let home { try? FileManager.default.removeItem(at: home) }
        if let paths { try? FileManager.default.removeItem(at: paths.root) }
    }

    private var claude: URL { home.appendingPathComponent(".claude") }

    @discardableResult
    private func write(_ folder: URL, name: String, front: String = "", body: String = "1. Do the thing.") throws -> URL {
        let dir = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        try "---\nname: \(name)\ndescription: The \(name) skill.\n\(front)---\n\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func json(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// The owner's morning and pdf skills; an enabled "designer" plugin whose manifest adds a folder; a plugin that's off;
    /// one installed for a single project. Returns designer's install folder.
    @discardableResult
    private func lay() throws -> URL {
        try write(claude.appendingPathComponent("skills"), name: "morning")
        try write(claude.appendingPathComponent("skills"), name: "pdf")
        // The owner's Claude account's skills, as Claude Code keeps them.
        try write(claude.appendingPathComponent("skills/synced/account-1"), name: "docx")
        let designer = home.appendingPathComponent("plugins/designer/1.0")
        try json(["name": "designer", "skills": "./.claude/skills/"], to: designer.appendingPathComponent(".claude-plugin/plugin.json"))
        try write(designer.appendingPathComponent(".claude/skills"), name: "palette", body: "Run `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/palette.py`.")
        try write(designer.appendingPathComponent("skills"), name: "fork-it", front: "context: fork\n")
        // A template deep in the plugin isn't one of its skills.
        try write(designer.appendingPathComponent("cli/assets/skills"), name: "template")
        let off = home.appendingPathComponent("plugins/off/1.0")
        try write(off.appendingPathComponent("skills"), name: "unused")
        let project = home.appendingPathComponent("plugins/project/1.0")
        try write(project.appendingPathComponent("skills"), name: "local-only")
        try json(["plugins": [
            "designer@market": [["scope": "user", "installPath": designer.path]],
            "off@market": [["scope": "user", "installPath": off.path]],
            "project@market": [["scope": "project", "installPath": project.path]],
        ]], to: claude.appendingPathComponent("plugins/installed_plugins.json"))
        try json(["enabledPlugins": ["designer@market": true, "off@market": false, "project@market": true]], to: claude.appendingPathComponent("settings.json"))
        return designer
    }

    private func linked() async throws -> [Skill] {
        try await store.listSkills(includeDisabled: true).filter { $0.origin == ClaudeCodeSkills.origin }
    }

    func testFindsTheOwnersSkillsAndEnabledPluginsSkillsOnly() throws {
        try lay()
        let found = ClaudeCodeSkills.sources(home: home)
        XCTAssertEqual(found.map { ($0.plugin.map { "\($0):" } ?? "") + $0.file.deletingLastPathComponent().lastPathComponent }.sorted(),
                       ["designer:fork-it", "designer:palette", "docx", "morning", "pdf"])
    }

    func testSyncLinksNamesAndRoutesThemAndLeavesPennantsOwnAlone() async throws {
        let designer = try lay()
        try await store.upsertSkill(Skill(name: "pdf", purpose: "Pennant's own.", status: .validated, origin: "imported"))
        let result = await ClaudeCodeSkills.sync(enabled: true, store: store, eventBus: bus, home: home)
        XCTAssertEqual(result.added.sorted(), ["designer:fork-it", "designer:palette", "docx", "morning"])
        XCTAssertEqual(result.skipped, ["pdf: one of Pennant's skills has this name"])
        let skills = try await linked()
        let palette = try XCTUnwrap(skills.first { $0.name == "designer:palette" })
        XCTAssertTrue(palette.body.contains("\(designer.path)/scripts/palette.py"), "the plugin's folder is filled in")
        XCTAssertNil(palette.needsClaudeCode, "Pennant follows it itself")
        XCTAssertEqual(skills.first { $0.name == "designer:fork-it" }?.needsClaudeCode, "it runs as an agent of its own in Claude Code")
        let pdf = try await store.listSkills(includeDisabled: true).filter { $0.name == "pdf" }
        XCTAssertEqual(pdf.map(\.origin), ["imported"])
        // Nothing changed, nothing to do.
        let again = await ClaudeCodeSkills.sync(enabled: true, store: store, eventBus: bus, home: home)
        XCTAssertFalse(again.changed)
    }

    func testEditsBecomeVersionsTurnedOffStaysOffAndGoneIsRemoved() async throws {
        let designer = try lay()
        _ = await ClaudeCodeSkills.sync(enabled: true, store: store, eventBus: bus, home: home)
        try write(claude.appendingPathComponent("skills"), name: "morning", body: "1. Read the calendar.\n2. Write the brief.")
        var result = await ClaudeCodeSkills.sync(enabled: true, store: store, eventBus: bus, home: home)
        XCTAssertEqual(result.updated, ["morning"])
        var morning = try await linked().filter { $0.name == "morning" }.sorted { $0.version < $1.version }
        XCTAssertEqual(morning.map(\.version), [1, 2])
        XCTAssertEqual(morning[1].previousVersionID, morning[0].id)

        // The owner turns it off in Pennant; Claude Code's next edit doesn't turn it back on.
        var off = morning[1]
        off.status = .disabled
        try await store.upsertSkill(off)
        try write(claude.appendingPathComponent("skills"), name: "morning", body: "1. Read the calendar and the inbox.")
        _ = await ClaudeCodeSkills.sync(enabled: true, store: store, eventBus: bus, home: home)
        morning = try await linked().filter { $0.name == "morning" }.sorted { $0.version < $1.version }
        XCTAssertEqual(morning.last?.version, 3)
        XCTAssertEqual(morning.last?.status, .disabled)

        try FileManager.default.removeItem(at: designer.appendingPathComponent(".claude/skills/palette"))
        result = await ClaudeCodeSkills.sync(enabled: true, store: store, eventBus: bus, home: home)
        XCTAssertEqual(result.removed, ["designer:palette"])
        let names = try await linked().map(\.name)
        XCTAssertFalse(names.contains("designer:palette"))

        // The link turned off removes them all.
        result = await ClaudeCodeSkills.sync(enabled: false, store: store, eventBus: bus, home: home)
        XCTAssertEqual(result.removed.sorted(), ["designer:fork-it", "docx", "morning", "pdf"])
        let left = try await linked()
        XCTAssertTrue(left.isEmpty)
    }

    func testWhatOnlyClaudeCodeCanRun() {
        XCTAssertNil(ClaudeCodeSkills.needsClaudeCode(front: [:], body: "1. Read the file.\n2. Write a summary."))
        XCTAssertEqual(ClaudeCodeSkills.needsClaudeCode(front: [:], body: "Dispatch three subagents in parallel."), "it starts subagents")
        XCTAssertEqual(ClaudeCodeSkills.needsClaudeCode(front: [:], body: "Use the Task tool with subagent_type general."), "it starts subagents")
        XCTAssertEqual(ClaudeCodeSkills.needsClaudeCode(front: ["agent": "Explore"], body: ""), "it runs as an agent of its own in Claude Code")
        XCTAssertEqual(ClaudeCodeSkills.needsClaudeCode(front: [:], body: "Branch: !`git branch --show-current`"), "it runs commands as Claude Code loads it")
        XCTAssertEqual(ClaudeCodeSkills.needsClaudeCode(front: [:], body: "Call mcp__claude-in-chrome__navigate first."), "it uses Claude Code's mcp__claude-in-chrome tools")
        XCTAssertEqual(ClaudeCodeSkills.needsClaudeCode(front: [:], body: "Then mcp__Claude_Browser__click."), "it uses Claude Code's mcp__Claude_Browser tools")
    }

    func testUseSkillHandsAClaudeCodeOnlySkillToClaudeCode() async throws {
        let store = FakeStore()
        let skill = Skill(name: "designer:fork-it", purpose: "Forks.", status: .validated, origin: ClaudeCodeSkills.origin, body: "Fork.", needsClaudeCode: "it starts subagents")
        try await store.upsertSkill(skill)
        let started = Locked<[String]>([])
        var hooks = RuntimeHooks(delegate: { _, _, _, _, _, _, _ in TaskID() }, awaitTask: { _, _ in throw ToolError.timeout }, askUser: { _, _ in "" }, learnSkill: { _, s in s },
                                 scheduleJob: { _, _, _, _ in throw ToolError.timeout }, deleteSchedule: { _ in }, importSkills: { _ in ([], []) })
        hooks.runInClaudeCode = { skill, request in
            started.set(started.get() + [skill.name, request])
            return (TaskID("cc-task"), ConversationID("cc-thread"))
        }
        let context = ToolContext(agentID: AgentID("a"), taskID: TaskID("t"), conversationID: ConversationID("c"), store: store, desktop: FakeDesktop(), lease: DesktopLease(), config: HostConfig(), runtimeHooks: hooks)
        let result = try await UseSkillTool(tracker: SkillUsageTracker()).invoke(["skill_id": "designer:fork-it", "request": "Redesign the pricing page."], context: context)
        XCTAssertEqual(started.get(), ["designer:fork-it", "Redesign the pricing page."])
        XCTAssertTrue(result.textContent.contains("runs in Claude Code (it starts subagents)"), result.textContent)
        XCTAssertTrue(result.textContent.contains("task cc-task"))
    }

    func testReadsTheSkillPickedFromTheList() {
        XCTAssertEqual(TaskRuntime.pickedSkill(in: "Use the skill \"price-check\": compare the three team plans")?.name, "price-check")
        XCTAssertEqual(TaskRuntime.pickedSkill(in: "Use the skill \"price-check\": compare the three team plans")?.request, "compare the three team plans")
        XCTAssertEqual(TaskRuntime.pickedSkill(in: "Use the skill “designer:palette”: ")?.name, "designer:palette")
        XCTAssertEqual(TaskRuntime.pickedSkill(in: "Use the skill “designer:palette”: ")?.request, "")
        XCTAssertNil(TaskRuntime.pickedSkill(in: "Can you use a skill for this?"))
    }

    func testAPickedPennantSkillGoesToAThreadThatFollowsIt() async throws {
        let hostPaths = HostPaths.temporary()
        try hostPaths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: hostPaths.root) }
        var config = HostConfig()
        config.workingDirectory = hostPaths.root.path
        config.desktop.pauseOnHumanInput = false
        let provider = ScriptedProvider([])
        provider.chatTurns = [.init(text: "On its way.")]
        let s = try HostService(paths: hostPaths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        try await s.store.upsertSkill(Skill(name: "morning", purpose: "A morning brief.", status: .validated, origin: ClaudeCodeSkills.origin, body: "1. Read the calendar."))
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, ask) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Use the skill \"morning\": for tomorrow", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while try await s.store.task(ask)?.state != .completed, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let request = try XCTUnwrap(provider.requests.first { $0.messages.first?.text.contains("## The Pennant chat") == true })
        let everything = request.messages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(everything.contains("They picked the skill \"morning\" from the list. Don't do it with your own tools: start_thread now, with instructions that begin \"Call use_skill with 'morning' and follow it:\""), "the chat is told to hand it to a thread")
        await s.stop()
    }

    /// The chat doesn't try a Claude Code skill with its own tools: the turn starts the run, invoked by the skill's name
    /// (with Chrome for one that browses with Claude in Chrome), and says so. A stand-in for the CLI, first on PATH, notes
    /// how it was started.
    func testAPickedClaudeCodeSkillStartsThereWithoutTheChatTryingIt() async throws {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let argsFile = home.appendingPathComponent("args.txt")
        let claude = bin.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf '%s\n' "$@" > '\(argsFile.path)'
        echo '{"type":"system","subtype":"init","session_id":"s-1","model":"claude-opus-5-5"}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"Visited three sites.","session_id":"s-1","total_cost_usd":0.01,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":1}}'
        """.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(bin.path):\(path)", 1)
        defer { setenv("PATH", path, 1) }

        let hostPaths = HostPaths.temporary()
        try hostPaths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: hostPaths.root) }
        var config = HostConfig()
        config.workingDirectory = hostPaths.root.path
        config.desktop.pauseOnHumanInput = false
        let provider = ScriptedProvider([])
        let s = try HostService(paths: hostPaths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let skill = Skill(name: "designer:browse", purpose: "Browses.", status: .validated, origin: ClaudeCodeSkills.origin,
                          body: "Open pages with mcp__claude-in-chrome__navigate.", needsClaudeCode: "it uses Claude Code's mcp__claude-in-chrome tools")
        try await s.store.upsertSkill(skill)

        let chat = try await s.runtime.ensureMainChat()
        let (_, _, ask) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Use the skill \"designer:browse\": compare the three team plans", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while try await s.store.task(ask)?.state != .completed, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let said = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 50).filter { $0.taskID == ask && $0.role == .assistant }
        XCTAssertEqual(said.map(\.text), ["designer:browse runs in Claude Code, so I've started it there. I'll tell you what it comes back with."])
        let tried = try await s.store.recentToolRecords(limit: 50).filter { $0.taskID == ask }
        XCTAssertTrue(tried.isEmpty, "the chat used no tools of its own: \(tried.map(\.call.name))")

        let conversations = try await s.store.listConversations(agentID: chat.agentID)
        let thread = try XCTUnwrap(conversations.first { $0.engine == .claudeCode })
        XCTAssertEqual(thread.engineChrome, true)
        XCTAssertEqual(thread.title, "designer:browse: compare the three team plans")
        while !FileManager.default.fileExists(atPath: argsFile.path), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let args = try String(contentsOf: argsFile, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(args.dropFirst().first, "/designer:browse compare the three team plans", "invoked by name")
        XCTAssertTrue(args.contains("--chrome"))
        await s.stop()
    }
}
